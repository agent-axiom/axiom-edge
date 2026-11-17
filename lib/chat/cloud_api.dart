import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/models.dart';
import 'chat_models.dart';

/// Safe for UI display: provider bodies, headers and credentials are never kept.
class CloudApiException implements Exception {
  const CloudApiException(
    this.message, {
    this.code = 'request_error',
    this.statusCode,
  });

  final String message;
  final String code;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Direct BYOK transport. Each operation owns its client so stopping one request
/// aborts its connection without poisoning the next request or retaining keys.
class HttpCloudGateway implements CloudGateway {
  HttpCloudGateway({
    http.Client Function()? clientFactory,
    Duration requestTimeout = const Duration(seconds: 30),
    Duration idleTimeout = const Duration(minutes: 3),
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _requestTimeout = requestTimeout,
       _idleTimeout = idleTimeout {
    if (requestTimeout <= Duration.zero || idleTimeout <= Duration.zero) {
      throw ArgumentError('Timeouts must be positive');
    }
  }

  final http.Client Function() _clientFactory;
  final Duration _requestTimeout;
  final Duration _idleTimeout;
  final Set<_Operation> _active = {};
  bool _closed = false;

  static Uri _endpoint(CloudProvider provider, {required bool models}) =>
      switch (provider) {
        CloudProvider.openai => Uri.parse(
          models
              ? 'https://api.openai.com/v1/models'
              : 'https://api.openai.com/v1/responses',
        ),
        CloudProvider.zai => Uri.parse(
          models
              ? 'https://api.z.ai/api/paas/v4/models'
              : 'https://api.z.ai/api/paas/v4/chat/completions',
        ),
      };

  _Operation _begin() {
    if (_closed) {
      throw const CloudApiException('Подключение уже закрыто.', code: 'closed');
    }
    final operation = _Operation(_clientFactory());
    _active.add(operation);
    return operation;
  }

  void _end(_Operation operation) {
    _active.remove(operation);
    operation.closeClient();
  }

  static String _key(String value) {
    final key = value.trim();
    if (key.isEmpty) {
      throw const CloudApiException(
        'Добавьте API-ключ выбранного провайдера.',
        code: 'missing_key',
      );
    }
    if (key.codeUnits.any((code) => code < 33 || code > 126)) {
      throw const CloudApiException(
        'Вставьте только API-ключ, без Bearer, пробелов и переносов строк.',
        code: 'invalid_key',
      );
    }
    return key;
  }

  static http.Request _request(
    String method,
    Uri url,
    String apiKey, {
    bool stream = false,
  }) => http.Request(method, url)
    ..followRedirects = false
    ..maxRedirects = 0
    ..headers.addAll({
      'Authorization': 'Bearer $apiKey',
      'Accept': stream ? 'text/event-stream' : 'application/json',
      if (method == 'POST') 'Content-Type': 'application/json; charset=utf-8',
    });

  @override
  Future<List<String>> listModels(CloudProvider provider, String apiKey) async {
    final key = _key(apiKey);
    final operation = _begin();
    try {
      final response = await operation.wait(
        operation.client.send(
          _request('GET', _endpoint(provider, models: true), key),
        ),
        _requestTimeout,
      );
      if (response.statusCode != 200) {
        throw await _httpError(response, operation, catalog: true);
      }
      final text = await _body(response, operation, maxBytes: 4 * 1024 * 1024);
      final payload = _object(jsonDecode(text));
      final data = payload?['data'];
      if (data is! List) throw _invalid();
      final ids = <String>{};
      for (final entry in data) {
        final id = _object(entry)?['id'];
        if (id is! String || id.trim().isEmpty || _hasControls(id)) {
          throw _invalid();
        }
        ids.add(id);
      }
      return ids.toList()..sort();
    } catch (error) {
      throw _safeError(error, operation);
    } finally {
      _end(operation);
    }
  }

  @override
  Stream<CloudChunk> stream({
    required CloudProvider provider,
    required String apiKey,
    required String model,
    required List<ChatTurn> messages,
    String systemPrompt = '',
  }) async* {
    final key = _key(apiKey);
    final selectedModel = model.trim();
    if (selectedModel.isEmpty || _hasControls(selectedModel)) {
      throw const CloudApiException(
        'Выберите модель или укажите её ID.',
        code: 'missing_model',
      );
    }
    if (messages.isEmpty ||
        messages.any(
          (turn) =>
              !{'user', 'assistant', 'system', 'developer'}.contains(turn.role),
        )) {
      throw const CloudApiException(
        'История чата содержит неверные сообщения.',
        code: 'invalid_messages',
      );
    }
    final operation = _begin();
    try {
      final request = _request(
        'POST',
        _endpoint(provider, models: false),
        key,
        stream: true,
      );
      request.body = jsonEncode(
        provider == CloudProvider.openai
            ? {
                'model': selectedModel,
                'input': messages.map((turn) => turn.toJson()).toList(),
                if (systemPrompt.trim().isNotEmpty)
                  'instructions': systemPrompt,
                'stream': true,
                'store': false,
              }
            : {
                'model': selectedModel,
                'messages': [
                  if (systemPrompt.trim().isNotEmpty)
                    ChatTurn('system', systemPrompt).toJson(),
                  ...messages.map((turn) => turn.toJson()),
                ],
                'stream': true,
              },
      );
      final response = await operation.wait(
        operation.client.send(request),
        _requestTimeout,
      );
      if (response.statusCode != 200) {
        throw await _httpError(response, operation);
      }
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      if (contentType.isNotEmpty &&
          !contentType.contains('text/event-stream')) {
        final text = await _body(response, operation, maxBytes: 64 * 1024);
        final payload = _object(jsonDecode(text));
        if (payload?['error'] != null || payload?['code'] != null) {
          throw _apiError(null, payload);
        }
        throw const CloudApiException(
          'Провайдер вернул ответ без потоковой передачи. Проверьте выбранную модель.',
          code: 'unsupported',
        );
      }
      final events = _events(operation.bytes(response.stream, _idleTimeout));
      final chunks = provider == CloudProvider.openai
          ? _openai(events)
          : _zai(events);
      await for (final chunk in chunks) {
        if (operation.cancelled) throw _cancelled();
        yield chunk;
      }
    } catch (error) {
      throw _safeError(error, operation);
    } finally {
      _end(operation);
    }
  }

  Future<String> _body(
    http.StreamedResponse response,
    _Operation operation, {
    required int maxBytes,
  }) async {
    final output = BytesBuilder(copy: false);
    final clock = Stopwatch()..start();
    final iterator = StreamIterator(response.stream);
    try {
      while (await operation.wait(
        iterator.moveNext(),
        _requestTimeout - clock.elapsed,
      )) {
        output.add(iterator.current);
        if (output.length > maxBytes) throw _invalid();
      }
    } finally {
      await iterator.cancel();
    }
    return utf8.decode(output.takeBytes());
  }

  Future<CloudApiException> _httpError(
    http.StreamedResponse response,
    _Operation operation, {
    bool catalog = false,
  }) async {
    if (response.statusCode >= 300 && response.statusCode < 400) {
      return CloudApiException(
        'Провайдер вернул перенаправление. API-ключ не отправлен на другой адрес.',
        code: 'redirect',
        statusCode: response.statusCode,
      );
    }
    Object? payload;
    try {
      payload = jsonDecode(
        await _body(response, operation, maxBytes: 64 * 1024),
      );
    } catch (_) {
      if (operation.cancelled) return _cancelled();
      // An unreadable error body must not hide the known HTTP status.
    }
    return _apiError(response.statusCode, payload, catalog: catalog);
  }

  @override
  void cancel() {
    for (final operation in _active.toList()) {
      operation.cancel();
    }
  }

  @override
  void close() {
    _closed = true;
    cancel();
  }
}

class _Operation {
  _Operation(this.client);
  final http.Client client;
  final Completer<void> _cancellation = Completer<void>();
  bool _clientClosed = false;
  bool get cancelled => _cancellation.isCompleted;

  Future<T> wait<T>(Future<T> pending, Duration timeout) {
    if (cancelled) {
      pending.ignore();
      return Future.error(_cancelled());
    }
    if (timeout <= Duration.zero) {
      pending.ignore();
      return Future.error(TimeoutException('Request timed out'));
    }
    return Future.any([
      pending,
      _cancellation.future.then<T>((_) => throw _cancelled()),
    ]).timeout(timeout);
  }

  Stream<List<int>> bytes(
    Stream<List<int>> source,
    Duration idleTimeout,
  ) async* {
    final iterator = StreamIterator(source);
    var received = 0;
    try {
      while (await wait(iterator.moveNext(), idleTimeout)) {
        received += iterator.current.length;
        if (received > 16 * 1024 * 1024) {
          throw const CloudApiException(
            'Ответ слишком большой. Сократите запрос.',
            code: 'invalid_response',
          );
        }
        yield iterator.current;
      }
    } finally {
      await iterator.cancel();
    }
  }

  void cancel() {
    if (cancelled) return;
    _cancellation.complete();
    closeClient();
  }

  void closeClient() {
    if (_clientClosed) return;
    _clientClosed = true;
    client.close();
  }
}

class _SseEvent {
  const _SseEvent(this.type, this.data);
  final String type;
  final String data;
}

Stream<_SseEvent> _events(Stream<List<int>> source) async* {
  var type = '';
  var data = <String>[];
  var eventSize = 0;
  var firstLine = true;
  await for (var line
      in source.transform(utf8.decoder).transform(const LineSplitter())) {
    if (firstLine && line.startsWith('\uFEFF')) line = line.substring(1);
    firstLine = false;
    if (line.isEmpty) {
      if (data.isNotEmpty) yield _SseEvent(type, data.join('\n'));
      type = '';
      data = [];
      eventSize = 0;
      continue;
    }
    eventSize += line.length;
    if (eventSize > 2 * 1024 * 1024) throw _invalid();
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') type = value;
    if (field == 'data') data.add(value);
  }
  // Do not dispatch an unterminated event at EOF: a broken connection is not a
  // successful terminal marker, even if its final JSON happened to be complete.
}

Stream<CloudChunk> _openai(Stream<_SseEvent> events) async* {
  var hasText = false;
  var refusal = false;
  await for (final event in events) {
    if (event.data.trim().isEmpty) continue;
    final payload = _object(jsonDecode(event.data));
    if (payload == null) throw _invalid();
    final type = payload['type'] ?? event.type;
    if (event.type == 'error' || type == 'error' || payload['error'] != null) {
      throw _apiError(null, payload);
    }
    switch (type) {
      case 'response.output_text.delta':
      case 'response.refusal.delta':
        final delta = payload['delta'];
        if (delta is! String) throw _invalid();
        refusal = refusal || type == 'response.refusal.delta';
        if (delta.isNotEmpty) {
          hasText = true;
          yield CloudChunk(textDelta: delta);
        }
      case 'response.refusal.done':
        refusal = true;
        final text = payload['refusal'];
        if (!hasText && text is String && text.isNotEmpty) {
          hasText = true;
          yield CloudChunk(textDelta: text);
        }
      case 'response.reasoning_summary_text.delta':
        final delta = payload['delta'];
        if (delta is! String) throw _invalid();
        if (delta.isNotEmpty) yield CloudChunk(reasoningDelta: delta);
      case 'response.failed':
        throw _apiError(null, payload['response'] ?? payload);
      case 'response.incomplete':
        final response = _object(payload['response']);
        throw _finishError(
          _object(response?['incomplete_details'])?['reason'] as String?,
        );
      case 'response.cancelled':
        throw const CloudApiException(
          'Провайдер остановил генерацию ответа.',
          code: 'stream_error',
        );
      case 'response.completed':
        final response = _object(payload['response']);
        if (response?['error'] != null) throw _apiError(null, response);
        final status = response?['status'];
        if (status != null && status != 'completed') {
          throw _finishError(
            _object(response?['incomplete_details'])?['reason'] as String?,
          );
        }
        if (!hasText) {
          final output = response?['output'];
          if (output is List) {
            for (final item in output) {
              final content = _object(item)?['content'];
              if (content is! List) continue;
              for (final part in content) {
                final block = _object(part);
                if (block == null) continue;
                final text = block['type'] == 'refusal'
                    ? block['refusal']
                    : block['text'];
                if (block['type'] == 'refusal') refusal = true;
                if (text is String && text.isNotEmpty) {
                  hasText = true;
                  yield CloudChunk(textDelta: text);
                }
              }
            }
          }
        }
        if (!hasText) throw _noText();
        yield CloudChunk(
          done: true,
          finishReason: refusal ? 'refusal' : 'completed',
          usage: _usage(response?['usage']),
        );
        return;
    }
  }
  throw _unexpectedEof();
}

Stream<CloudChunk> _zai(Stream<_SseEvent> events) async* {
  String? finishReason;
  Map<String, Object?>? usage;
  var hasText = false;
  var refusal = false;
  await for (final event in events) {
    final data = event.data.trim();
    if (data.isEmpty) continue;
    if (data == '[DONE]') {
      if (finishReason != null && !{'stop', 'refusal'}.contains(finishReason)) {
        throw _finishError(finishReason);
      }
      if (!hasText) throw _noText();
      yield CloudChunk(
        done: true,
        finishReason: refusal ? 'refusal' : finishReason ?? 'completed',
        usage: usage,
      );
      return;
    }
    final payload = _object(jsonDecode(event.data));
    if (payload == null) throw _invalid();
    if (event.type == 'error' ||
        payload['error'] != null ||
        (payload['code'] != null && payload['choices'] == null)) {
      throw _apiError(null, payload);
    }
    usage = _usage(payload['usage']) ?? usage;
    final choices = payload['choices'];
    if (choices is! List) throw _invalid();
    if (choices.isEmpty) continue;
    final choice = _object(choices.first);
    if (choice == null) throw _invalid();
    final index = choice['index'];
    if (index != null && index != 0) continue;
    final delta = _object(choice['delta']);
    if (delta != null) {
      final reasoning = delta['reasoning_content'];
      if (reasoning != null && reasoning is! String) throw _invalid();
      if (reasoning is String && reasoning.isNotEmpty) {
        yield CloudChunk(reasoningDelta: reasoning);
      }
      final text = delta['content'];
      if (text != null && text is! String) throw _invalid();
      if (text is String && text.isNotEmpty) {
        hasText = true;
        yield CloudChunk(textDelta: text);
      }
      final denied = delta['refusal'];
      if (denied != null && denied is! String) throw _invalid();
      if (denied is String && denied.isNotEmpty) {
        hasText = true;
        refusal = true;
        yield CloudChunk(textDelta: denied);
      }
    }
    final reason = choice['finish_reason'];
    if (reason != null && reason is! String) throw _invalid();
    if (reason is String && reason.isNotEmpty) finishReason = reason;
    // finish_reason is not the SSE terminal marker. Keep consuming usage and
    // errors until [DONE], so a later server error cannot look like success.
  }
  throw _unexpectedEof();
}

Map<String, dynamic>? _object(Object? value) =>
    value is Map<String, dynamic> ? value : null;
Map<String, Object?>? _usage(Object? value) =>
    value is Map<String, dynamic> ? Map<String, Object?>.from(value) : null;
bool _hasControls(String value) =>
    value.codeUnits.any((code) => code < 32 || code == 127);

CloudApiException _cancelled() =>
    const CloudApiException('Запрос остановлен.', code: 'cancelled');
CloudApiException _invalid() => const CloudApiException(
  'Провайдер вернул некорректный ответ.',
  code: 'invalid_response',
);
CloudApiException _noText() => const CloudApiException(
  'Модель не вернула текстовый ответ. Выберите модель для текстового чата.',
  code: 'unsupported',
);
CloudApiException _unexpectedEof() => const CloudApiException(
  'Соединение прервалось до завершения ответа. Частичный текст сохранён.',
  code: 'stream_error',
);

CloudApiException _safeError(Object error, _Operation operation) {
  if (operation.cancelled) return _cancelled();
  if (error is CloudApiException) return error;
  if (error is TimeoutException) {
    return const CloudApiException(
      'Провайдер долго не отвечает. Повторите запрос позже.',
      code: 'timeout',
    );
  }
  if (error is FormatException || error is TypeError) return _invalid();
  return const CloudApiException(
    'Не удалось соединиться с провайдером. Проверьте сеть и повторите запрос.',
    code: 'connection',
  );
}

CloudApiException _finishError(String? reason) => switch (reason) {
  'length' || 'max_output_tokens' => const CloudApiException(
    'Ответ достиг лимита длины. Частичный текст сохранён.',
    code: 'incomplete',
  ),
  'sensitive' || 'content_filter' => const CloudApiException(
    'Провайдер остановил ответ по правилам обработки содержимого.',
    code: 'incomplete',
  ),
  'model_context_window_exceeded' => const CloudApiException(
    'История превысила контекст модели. Начните новый чат или сократите запрос.',
    code: 'incomplete',
  ),
  'tool_calls' => const CloudApiException(
    'Модель запросила инструменты, которые этот чат не запускает.',
    code: 'unsupported',
  ),
  _ => const CloudApiException(
    'Провайдер не завершил ответ. Частичный текст сохранён.',
    code: 'incomplete',
  ),
};

CloudApiException _apiError(
  int? status,
  Object? value, {
  bool catalog = false,
}) {
  final payload = _object(value);
  final error = _object(payload?['error']) ?? payload;
  // Inspect provider diagnostics only to select a static message. Echoed keys,
  // authorization headers and arbitrary server text never enter UI exceptions.
  final diagnostic =
      '${error?['code'] ?? ''} ${error?['type'] ?? ''} ${error?['message'] ?? ''}'
          .toLowerCase();
  String code;
  String message;
  if (status == 401 ||
      diagnostic.contains('invalid_api_key') ||
      diagnostic.contains('authentication_error')) {
    code = 'unauthorized';
    message = 'API-ключ не принят. Проверьте ключ выбранного провайдера.';
  } else if (status == 403) {
    code = 'forbidden';
    message =
        'Доступ запрещён. Проверьте права ключа, доступ к API и квоту аккаунта.';
  } else if (status == 429 ||
      diagnostic.contains('rate_limit') ||
      diagnostic.contains('insufficient_quota')) {
    code = 'rate_limited';
    message =
        'Превышен лимит API или закончилась квота. Проверьте баланс и повторите запрос позже.';
  } else if (catalog && {404, 405, 501}.contains(status)) {
    code = 'catalog_unavailable';
    message =
        'Провайдер не предоставил список моделей по API. Укажите ID модели вручную.';
  } else if (status == 404 ||
      diagnostic.contains('model_not_found') ||
      diagnostic.contains('invalid_model')) {
    code = 'model_unavailable';
    message =
        'Модель недоступна для этого ключа. Обновите список моделей или проверьте её ID.';
  } else if (status != null && status >= 500) {
    code = 'server_error';
    message = 'Сервис провайдера временно недоступен. Повторите запрос позже.';
  } else {
    code = status == null ? 'stream_error' : 'request_error';
    message =
        'Провайдер отклонил запрос. Проверьте модель и её поддержку текстового чата.';
  }
  return CloudApiException(
    status == null ? message : '$message (HTTP $status)',
    code: code,
    statusCode: status,
  );
}
