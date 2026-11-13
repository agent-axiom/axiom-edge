import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:mnn_engine/mnn_engine.dart';

import '../core/models.dart';
import '../core/runner.dart';

/// Android-only adapter. The MNN service is bound to loopback and protected by
/// an ephemeral key; no public Wi-Fi API is exposed.
class MnnRunner implements ModelRunner {
  MnnRunner() : _client = http.Client();
  final http.Client _client;
  final _engine = MnnEngine.instance;
  String? _modelId;
  Uri? _url;
  String? _secret;

  @override
  Map<String, Object?> get configuration => {
    'runtime_package': 'mnn_engine',
    'runtime_package_version': '0.2.0',
    'model_parameters': 'imported model configuration / plugin defaults',
    'generation_defaults': {
      'max_tokens': 128,
      'temperature': 0.8,
      'seed': null,
      'reuse_prompt_prefix': null,
      'sampling_parameters': 'imported model configuration',
    },
    'supported_controls': {'seed': false, 'reuse_prompt_prefix': false},
    'temperature_control':
        'requested via HTTP; the model-load sampler may '
        'prevent request temperature=0 from ensuring greedy decoding',
    'prompt_cache_policy': 'backend managed; not controlled by this adapter',
    'ttft_definition':
        'application elapsed time to first nonempty SSE text '
        'delta; includes HTTP framing, scheduling and server buffering',
    'throughput_definition':
        'reported completion tokens / whole request '
        'wall-clock time; not native decode throughput',
  };

  @override
  Future<void> load(LocalModel model) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('MNN currently supports Android only');
    }
    if (model.format != ModelFormat.mnn) {
      throw ArgumentError('Expected MNN model');
    }
    await _stop();
    final info = await _engine.initialize();
    if (!info.nativeLibraryLoaded) {
      throw StateError('MNN native library not available');
    }
    try {
      await _engine.loadModel(model.location);
      _modelId = model.location;
      _secret = _generateSecret();
      final server = await _engine.startServer(port: 8081, apiKey: _secret);
      _url = Uri.parse('${server.baseUrl}/v1/chat/completions');
    } catch (_) {
      await _stop();
      rethrow;
    }
  }

  static String _generateSecret() {
    final r = Random.secure();
    return List.generate(
      32,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  @override
  Future<GenerationResult> generate(
    List<ChatTurn> history, {
    int maxTokens = 128,
    double temperature = 0.8,
    int? seed,
    bool reusePromptPrefix = true,
    TextDelta? onDelta,
  }) async {
    final endpoint = _url;
    if (endpoint == null || _modelId == null) {
      throw StateError('Load an MNN model first');
    }
    final clock = Stopwatch()..start();
    final request = http.Request('POST', endpoint)
      ..headers.addAll({
        'Authorization': 'Bearer $_secret',
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
      })
      ..body = jsonEncode({
        'model': _modelId,
        'messages': history.map((m) => m.toJson()).toList(),
        'stream': true,
        'max_tokens': maxTokens,
        'temperature': temperature,
        'stream_options': {'include_usage': true},
      });
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      final message = await response.stream.bytesToString();
      throw HttpException('MNN ${response.statusCode}: $message');
    }
    final buffer = StringBuffer();
    int? ttft;
    int? outputTokens;
    var sawDone = false;
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final raw = line.substring(5).trim();
      if (raw == '[DONE]') {
        sawDone = true;
        break;
      }
      if (raw.isEmpty) continue;
      final event = jsonDecode(raw);
      if (event is! Map<String, dynamic>) continue;
      final streamError = event['error'];
      if (streamError != null) {
        throw HttpException('MNN generation failed: $streamError');
      }
      final usage = event['usage'];
      if (usage is Map<String, dynamic>) {
        outputTokens =
            (usage['completion_tokens'] as num?)?.toInt() ?? outputTokens;
      }
      final choices = event['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final choice = choices.first;
      if (choice is! Map) continue;
      if (choice['finish_reason'] == 'cancelled') {
        throw StateError('MNN generation was cancelled by the runtime');
      }
      final delta = choice['delta'];
      final content = delta is Map ? delta['content'] : null;
      if (content is! String || content.isEmpty) continue;
      ttft ??= clock.elapsedMilliseconds;
      buffer.write(content);
      onDelta?.call(content);
    }
    clock.stop();
    if (!sawDone) {
      throw const HttpException('MNN stream ended without a completion marker');
    }
    // The first delta can contain several tokens. Without its token count,
    // subtracting TTFT but keeping all output tokens overstates throughput.
    // This is an end-to-end SSE estimate, never native decode throughput.
    return GenerationResult(
      buffer.toString(),
      InferenceMetrics(
        totalMs: clock.elapsedMilliseconds,
        ttftMs: ttft,
        decodeTokens: outputTokens,
        decodeTps: InferenceMetrics.rate(
          outputTokens,
          clock.elapsedMilliseconds,
        ),
        source: 'sse-wallclock',
      ),
    );
  }

  @override
  void cancel() {
    _engine.cancelGeneration();
  }

  Future<void> _stop() async {
    if (_url != null) await _engine.stopServer();
    _url = null;
    _secret = null;
    if (_modelId != null) await _engine.unloadModel();
    _modelId = null;
  }

  @override
  Future<void> dispose() async {
    try {
      await _stop();
    } finally {
      _client.close();
    }
  }
}
