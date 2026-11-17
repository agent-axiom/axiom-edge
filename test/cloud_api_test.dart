import 'dart:async';
import 'dart:convert';

import 'package:axiom_edge/chat/chat_models.dart';
import 'package:axiom_edge/chat/cloud_api.dart';
import 'package:axiom_edge/core/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _key = 'sk-test-only-sensitive-fixture';
const _messages = [ChatTurn('user', 'Привет')];

class _Client extends http.BaseClient {
  _Client(this.respond, {this.onClose});

  final FutureOr<http.StreamedResponse> Function(http.BaseRequest) respond;
  final void Function()? onClose;
  final requests = <http.BaseRequest>[];
  final started = Completer<void>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (!started.isCompleted) started.complete();
    return respond(request);
  }

  @override
  void close() {
    closed = true;
    onClose?.call();
  }
}

http.StreamedResponse _response(
  String body, {
  int status = 200,
  String contentType = 'text/event-stream; charset=utf-8',
  int fragmentSize = 7,
  Map<String, String> headers = const {},
}) {
  final bytes = utf8.encode(body);
  return http.StreamedResponse(
    Stream.fromIterable([
      for (var index = 0; index < bytes.length; index += fragmentSize)
        bytes.sublist(
          index,
          index + fragmentSize > bytes.length
              ? bytes.length
              : index + fragmentSize,
        ),
    ]),
    status,
    headers: {'content-type': contentType, ...headers},
  );
}

String _event(Map<String, Object?> value) => 'data: ${jsonEncode(value)}\n\n';

String _completed({Map<String, Object?>? usage}) => _event({
  'type': 'response.completed',
  'response': {'status': 'completed', 'output': <Object?>[], 'usage': ?usage},
});

String _openaiText(String text) =>
    _event({'type': 'response.output_text.delta', 'delta': text});

String _zaiText(String text) => _event({
  'choices': [
    {
      'index': 0,
      'delta': {'content': text},
    },
  ],
});

String _zaiFinish(String reason, {Map<String, Object?>? usage}) => _event({
  'choices': [
    {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': reason},
  ],
  'usage': ?usage,
});

String? _authorization(http.BaseRequest request) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == 'authorization') return entry.value;
  }
  return null;
}

class _Capture {
  const _Capture(this.chunks, this.error);
  final List<CloudChunk> chunks;
  final Object? error;
  String get text => chunks.map((chunk) => chunk.textDelta).join();
  String get reasoning => chunks.map((chunk) => chunk.reasoningDelta).join();
}

Future<_Capture> _capture(
  Stream<CloudChunk> source, {
  void Function(CloudChunk)? onChunk,
}) async {
  final chunks = <CloudChunk>[];
  try {
    await for (final chunk in source) {
      chunks.add(chunk);
      onChunk?.call(chunk);
    }
    return _Capture(chunks, null);
  } catch (error) {
    return _Capture(chunks, error);
  }
}

Stream<CloudChunk> _stream(
  HttpCloudGateway gateway, {
  CloudProvider provider = CloudProvider.openai,
  String model = 'account-owned-text-model',
  List<ChatTurn> messages = _messages,
  String systemPrompt = '',
}) => gateway.stream(
  provider: provider,
  apiKey: _key,
  model: model,
  messages: messages,
  systemPrompt: systemPrompt,
);

void _expectSafeError(Object? error, {String? code}) {
  expect(error, isA<CloudApiException>());
  expect(error.toString(), isNot(contains(_key)));
  expect(error.toString(), isNot(contains('Bearer $_key')));
  if (code != null) expect((error! as CloudApiException).code, code);
}

void main() {
  for (final provider in CloudProvider.values) {
    test(
      '${provider.name} discovers account models from the official host',
      () async {
        final client = _Client((request) {
          expect(request.method, 'GET');
          expect(
            request.url.toString(),
            provider == CloudProvider.openai
                ? 'https://api.openai.com/v1/models'
                : 'https://api.z.ai/api/paas/v4/models',
          );
          expect(_authorization(request), 'Bearer $_key');
          expect(request.followRedirects, isFalse);
          expect(request.maxRedirects, 0);
          return _response(
            jsonEncode({
              'data': [
                {'id': 'live-zeta'},
                {'id': 'live-alpha'},
                {'id': 'live-zeta'},
              ],
            }),
            contentType: 'application/json',
          );
        });
        final gateway = HttpCloudGateway(clientFactory: () => client);
        addTearDown(gateway.close);
        expect(await gateway.listModels(provider, '  $_key  '), [
          'live-alpha',
          'live-zeta',
        ]);
        expect(client.closed, isTrue);
      },
    );
  }

  test(
    'empty live catalog stays empty without invented fallback IDs',
    () async {
      final client = _Client(
        (_) => _response('{"data":[]}', contentType: 'application/json'),
      );
      final gateway = HttpCloudGateway(clientFactory: () => client);
      addTearDown(gateway.close);
      expect(await gateway.listModels(CloudProvider.openai, _key), isEmpty);
    },
  );

  test(
    'unsupported ZAI catalog is explicit and never becomes a fake roster',
    () async {
      final client = _Client(
        (_) => _response('{"error":{"message":"not found"}}', status: 404),
      );
      final gateway = HttpCloudGateway(clientFactory: () => client);
      addTearDown(gateway.close);
      await expectLater(
        gateway.listModels(CloudProvider.zai, _key),
        throwsA(
          isA<CloudApiException>().having(
            (error) => error.code,
            'code',
            'catalog_unavailable',
          ),
        ),
      );
    },
  );

  test(
    'malformed catalog is rejected instead of silently selecting a model',
    () async {
      final client = _Client(
        (_) => _response(
          '{"data":[{"name":"not an id"}]}',
          contentType: 'application/json',
        ),
      );
      final gateway = HttpCloudGateway(clientFactory: () => client);
      addTearDown(gateway.close);
      await expectLater(
        gateway.listModels(CloudProvider.openai, _key),
        throwsA(isA<CloudApiException>()),
      );
    },
  );

  test(
    'OpenAI uses minimal Responses input without model-specific parameters',
    () async {
      final client = _Client((request) {
        expect(request.url.toString(), 'https://api.openai.com/v1/responses');
        expect(request.method, 'POST');
        expect(request.followRedirects, isFalse);
        expect(request.maxRedirects, 0);
        expect(_authorization(request), 'Bearer $_key');
        final body =
            jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        expect(body, {
          'model': 'new-account-model',
          'input': [
            {'role': 'user', 'content': 'Question'},
            {'role': 'assistant', 'content': 'Earlier answer'},
            {'role': 'user', 'content': 'Follow up'},
          ],
          'instructions': 'Use Russian.',
          'stream': true,
          'store': false,
        });
        return _response(
          _openaiText('Ответ') +
              _completed(usage: {'input_tokens': 4, 'output_tokens': 2}),
        );
      });
      final gateway = HttpCloudGateway(clientFactory: () => client);
      addTearDown(gateway.close);
      final result = await _capture(
        _stream(
          gateway,
          model: 'new-account-model',
          messages: const [
            ChatTurn('user', 'Question'),
            ChatTurn('assistant', 'Earlier answer'),
            ChatTurn('user', 'Follow up'),
          ],
          systemPrompt: 'Use Russian.',
        ),
      );
      expect(result.error, isNull);
      expect(result.text, 'Ответ');
      expect(result.chunks.last.done, isTrue);
      expect(result.chunks.last.usage, {'input_tokens': 4, 'output_tokens': 2});
    },
  );

  test(
    'Responses SSE handles byte-fragmented UTF8, CRLF, comments and multiline data',
    () async {
      final wire =
          ': heartbeat\r\n\r\n'
          'event: response.output_text.delta\r\n'
          'data: {"type":"response.output_text.delta",\r\n'
          'data: "delta":"Привет 🌍"}\r\n\r\n'
          '${_completed()}';
      final client = _Client((_) => _response(wire, fragmentSize: 1));
      final gateway = HttpCloudGateway(clientFactory: () => client);
      addTearDown(gateway.close);
      final result = await _capture(_stream(gateway));
      expect(result.error, isNull);
      expect(result.text, 'Привет 🌍');
      expect(result.chunks.last.finishReason, 'completed');
    },
  );

  test(
    'OpenAI refusal is visible text with an explicit refusal finish reason',
    () async {
      final client = _Client(
        (_) => _response(
          _event({
                'type': 'response.refusal.delta',
                'delta': 'Не могу помочь с этим запросом.',
              }) +
              _completed(),
        ),
      );
      final gateway = HttpCloudGateway(clientFactory: () => client);
      addTearDown(gateway.close);
      final result = await _capture(_stream(gateway));
      expect(result.error, isNull);
      expect(result.text, 'Не могу помочь с этим запросом.');
      expect(result.chunks.last.done, isTrue);
      expect(result.chunks.last.finishReason, 'refusal');
    },
  );

  test(
    'OpenAI error event header overrides a contradictory text-delta payload',
    () async {
      final client = _Client(
        (_) => _response(
          [
            _openaiText('Сохранённая часть'),
            'event: error\n',
            _event({
              'type': 'response.output_text.delta',
              'delta': 'Ложный ответ $_key',
            }),
            _completed(),
          ].join(),
        ),
      );
      final gateway = HttpCloudGateway(clientFactory: () => client);
      addTearDown(gateway.close);
      final result = await _capture(_stream(gateway));
      expect(result.text, 'Сохранённая часть');
      expect(result.chunks.any((chunk) => chunk.done), isFalse);
      _expectSafeError(result.error);
    },
  );

  test(
    'ZAI uses its general endpoint and keeps reasoning separate from answer',
    () async {
      final client = _Client((request) {
        expect(
          request.url.toString(),
          'https://api.z.ai/api/paas/v4/chat/completions',
        );
        expect(request.followRedirects, isFalse);
        expect(request.maxRedirects, 0);
        final body = jsonDecode((request as http.Request).body);
        expect(body, {
          'model': 'account-owned-text-model',
          'messages': [
            {'role': 'system', 'content': 'Be concise.'},
            {'role': 'user', 'content': 'Привет'},
          ],
          'stream': true,
        });
        return _response(
          [
            _event({
              'choices': [
                {
                  'index': 0,
                  'delta': {'reasoning_content': 'Separate provider reasoning'},
                },
              ],
            }),
            _zaiText('Короткий ответ'),
            _zaiFinish(
              'stop',
              usage: {
                'prompt_tokens': 3,
                'completion_tokens': 4,
                'total_tokens': 7,
              },
            ),
            'data: [DONE]\n\n',
          ].join(),
        );
      });
      final gateway = HttpCloudGateway(clientFactory: () => client);
      addTearDown(gateway.close);
      final result = await _capture(
        _stream(
          gateway,
          provider: CloudProvider.zai,
          systemPrompt: 'Be concise.',
        ),
      );
      expect(result.error, isNull);
      expect(result.text, 'Короткий ответ');
      expect(result.reasoning, 'Separate provider reasoning');
      expect(result.text, isNot(contains('reasoning')));
      expect(result.chunks.last.done, isTrue);
      expect(result.chunks.last.finishReason, 'stop');
      expect(result.chunks.last.usage?['total_tokens'], 7);
    },
  );

  test(
    'ZAI error after finish_reason still wins until the DONE marker',
    () async {
      final client = _Client(
        (_) => _response(
          [
            _zaiText('Частичный ответ'),
            _zaiFinish('stop'),
            _event({
              'error': {'code': 'stream_error', 'message': 'Echo Bearer $_key'},
            }),
            'data: [DONE]\n\n',
          ].join(),
        ),
      );
      final gateway = HttpCloudGateway(clientFactory: () => client);
      addTearDown(gateway.close);
      final result = await _capture(
        _stream(gateway, provider: CloudProvider.zai),
      );
      expect(result.text, 'Частичный ответ');
      expect(result.chunks.any((chunk) => chunk.done), isFalse);
      _expectSafeError(result.error);
    },
  );

  for (final reason in [
    'length',
    'sensitive',
    'content_filter',
    'model_context_window_exceeded',
    'network_error',
    'tool_calls',
  ]) {
    test('ZAI $reason does not silently count as a complete answer', () async {
      final client = _Client(
        (_) => _response(
          [
            _zaiText('Сохранённая часть'),
            _zaiFinish(reason),
            'data: [DONE]\n\n',
          ].join(),
        ),
      );
      final gateway = HttpCloudGateway(clientFactory: () => client);
      addTearDown(gateway.close);
      final result = await _capture(
        _stream(gateway, provider: CloudProvider.zai),
      );
      expect(result.text, 'Сохранённая часть');
      expect(result.chunks.any((chunk) => chunk.done), isFalse);
      _expectSafeError(result.error);
    });
  }

  for (final provider in CloudProvider.values) {
    test(
      '${provider.name} EOF preserves partial text and reports interruption',
      () async {
        final client = _Client(
          (_) => _response(
            provider == CloudProvider.openai
                ? _openaiText('Часть')
                : _zaiText('Часть') + _zaiFinish('stop'),
          ),
        );
        final gateway = HttpCloudGateway(clientFactory: () => client);
        addTearDown(gateway.close);
        final result = await _capture(_stream(gateway, provider: provider));
        expect(result.text, 'Часть');
        expect(result.chunks.any((chunk) => chunk.done), isFalse);
        _expectSafeError(result.error);
      },
    );
  }

  for (final type in ['response.failed', 'response.incomplete', 'error']) {
    test(
      'OpenAI $type preserves partial text and hides echoed credentials',
      () async {
        final failure = type == 'error'
            ? {'type': type, 'code': 'server_error', 'message': _key}
            : {
                'type': type,
                'response': {
                  'status': type == 'response.failed' ? 'failed' : 'incomplete',
                  'error': {'code': 'server_error', 'message': _key},
                  'incomplete_details': {'reason': 'max_output_tokens'},
                },
              };
        final client = _Client(
          (_) => _response(_openaiText('Часть') + _event(failure)),
        );
        final gateway = HttpCloudGateway(clientFactory: () => client);
        addTearDown(gateway.close);
        final result = await _capture(_stream(gateway));
        expect(result.text, 'Часть');
        _expectSafeError(result.error);
      },
    );
  }

  test(
    'malformed SSE JSON cannot leak its content through decoder errors',
    () async {
      final client = _Client((_) => _response('data: {broken $_key\n\n'));
      final gateway = HttpCloudGateway(clientFactory: () => client);
      addTearDown(gateway.close);
      final result = await _capture(_stream(gateway));
      _expectSafeError(result.error, code: 'invalid_response');
    },
  );

  for (final status in [401, 403, 429, 500]) {
    test(
      'HTTP $status has a safe actionable exception without echoed key',
      () async {
        final client = _Client(
          (_) => _response(
            jsonEncode({
              'error': {
                'message': 'Authorization Bearer $_key',
                'code': 'failure',
              },
            }),
            status: status,
            contentType: 'application/json',
          ),
        );
        final gateway = HttpCloudGateway(clientFactory: () => client);
        addTearDown(gateway.close);
        final result = await _capture(_stream(gateway));
        _expectSafeError(result.error);
        expect((result.error! as CloudApiException).statusCode, status);
        expect(result.error.toString().trim(), isNotEmpty);
      },
    );
  }

  test('HTTP redirect is rejected without forwarding Authorization', () async {
    final client = _Client((request) {
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
      return _response(
        '',
        status: 307,
        headers: {'location': 'https://collector.invalid/steal'},
      );
    });
    final gateway = HttpCloudGateway(clientFactory: () => client);
    addTearDown(gateway.close);
    final result = await _capture(_stream(gateway));
    _expectSafeError(result.error);
    expect(client.requests, hasLength(1));
    expect(client.requests.single.url.host, 'api.openai.com');
  });

  test('network exceptions do not expose raw request or key', () async {
    final client = _Client(
      (_) => throw http.ClientException('connection failed using Bearer $_key'),
    );
    final gateway = HttpCloudGateway(clientFactory: () => client);
    addTearDown(gateway.close);
    final result = await _capture(_stream(gateway));
    _expectSafeError(result.error, code: 'connection');
  });

  test(
    'synchronous cancellation still consumes a later transport error',
    () async {
      late HttpCloudGateway gateway;
      final client = _Client((_) {
        gateway.cancel();
        return Future<http.StreamedResponse>.error(
          StateError('transport echoed $_key'),
        );
      });
      gateway = HttpCloudGateway(clientFactory: () => client);
      addTearDown(gateway.close);
      final result = await _capture(_stream(gateway));
      _expectSafeError(result.error, code: 'cancelled');
      expect(client.closed, isTrue);
      // Flush the losing send future; an unhandled error would fail this test.
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'cancel aborts pending headers and a later request uses a fresh client',
    () async {
      final pendingHeaders = Completer<http.StreamedResponse>();
      final first = _Client((_) => pendingHeaders.future);
      final second = _Client(
        (_) => _response(
          '{"data":[{"id":"after-cancel"}]}',
          contentType: 'application/json',
        ),
      );
      final clients = [first, second].iterator;
      final gateway = HttpCloudGateway(
        clientFactory: () {
          expect(clients.moveNext(), isTrue);
          return clients.current;
        },
      );
      addTearDown(gateway.close);
      final result = gateway.listModels(CloudProvider.openai, _key);
      final cancelled = expectLater(
        result,
        throwsA(
          isA<CloudApiException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      await first.started.future;
      gateway.cancel();
      await cancelled.timeout(const Duration(seconds: 2));
      expect(first.closed, isTrue);
      expect(await gateway.listModels(CloudProvider.openai, _key), [
        'after-cancel',
      ]);
    },
  );

  test(
    'cancelling an idle stream closes transport and retains received text',
    () async {
      final controller = StreamController<List<int>>();
      final client = _Client(
        (_) => http.StreamedResponse(
          controller.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
        onClose: () {
          unawaited(controller.close());
        },
      );
      final gateway = HttpCloudGateway(clientFactory: () => client);
      addTearDown(gateway.close);
      final firstText = Completer<void>();
      final pending = _capture(
        _stream(gateway),
        onChunk: (chunk) {
          if (chunk.textDelta.isNotEmpty && !firstText.isCompleted) {
            firstText.complete();
          }
        },
      );
      await client.started.future;
      controller.add(utf8.encode(_openaiText('Уже получено')));
      await firstText.future;
      gateway.cancel();
      final result = await pending.timeout(const Duration(seconds: 2));
      expect(result.text, 'Уже получено');
      _expectSafeError(result.error, code: 'cancelled');
      expect(client.closed, isTrue);
    },
  );

  test(
    'idle deadline exits a stalled stream after preserving its first text',
    () async {
      final controller = StreamController<List<int>>();
      final client = _Client(
        (_) => http.StreamedResponse(
          controller.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
        onClose: () {
          unawaited(controller.close());
        },
      );
      final gateway = HttpCloudGateway(
        clientFactory: () => client,
        idleTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(gateway.close);
      final pending = _capture(_stream(gateway));
      await client.started.future;
      controller.add(utf8.encode(_openaiText('Часть')));
      final result = await pending.timeout(const Duration(seconds: 2));
      expect(result.text, 'Часть');
      _expectSafeError(result.error, code: 'timeout');
      expect(client.closed, isTrue);
    },
  );

  test(
    'header deadline closes a client even when its send future never finishes',
    () async {
      final pendingHeaders = Completer<http.StreamedResponse>();
      final client = _Client((_) => pendingHeaders.future);
      final gateway = HttpCloudGateway(
        clientFactory: () => client,
        requestTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(gateway.close);
      final result = await _capture(
        _stream(gateway),
      ).timeout(const Duration(seconds: 2));
      _expectSafeError(result.error, code: 'timeout');
      expect(client.closed, isTrue);
    },
  );

  test(
    'closing the gateway cancels active work and rejects new requests',
    () async {
      final pendingHeaders = Completer<http.StreamedResponse>();
      final client = _Client((_) => pendingHeaders.future);
      final gateway = HttpCloudGateway(clientFactory: () => client);
      final result = _capture(_stream(gateway));
      await client.started.future;
      gateway.close();
      _expectSafeError(
        (await result.timeout(const Duration(seconds: 2))).error,
        code: 'cancelled',
      );
      await expectLater(
        gateway.listModels(CloudProvider.openai, _key),
        throwsA(isA<CloudApiException>()),
      );
      expect(client.closed, isTrue);
    },
  );
}
