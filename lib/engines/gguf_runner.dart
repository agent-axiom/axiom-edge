import 'package:llamadart/llamadart.dart' hide ModelFormat;

import '../core/models.dart';
import '../core/runner.dart';

class GgufRunner implements ModelRunner {
  LlamaEngine? _engine;

  @override
  Map<String, Object?> get configuration => {
    'runtime_package': 'llamadart',
    'runtime_package_version': '0.19.3',
    'model_parameters': {
      'context_size': 4096,
      'use_mmap': true,
      'other_parameters': 'pinned runtime defaults',
    },
    'generation_defaults': {
      'max_tokens': 128,
      'temperature': 0.8,
      'seed': null,
      'reuse_prompt_prefix': true,
      'top_k': 40,
      'top_p': 0.9,
      'min_p': 0.0,
      'repeat_penalty': 1.1,
      'presence_penalty': 0.0,
      'speculative_decoding': false,
      'stream_batch_token_threshold': 8,
      'stream_batch_byte_threshold': 512,
    },
    'supported_controls': {'seed': true, 'reuse_prompt_prefix': true},
    'ttft_definition':
        'application elapsed time to first nonempty text delta; '
        'includes template rendering, scheduling and stream batching',
    'throughput_definition':
        'per-request native evaluation tokens / '
        'native evaluation time; prefill counts evaluated prompt tokens',
    'performance_counters': 'reset by llamadart before every generation',
  };

  @override
  Future<void> load(LocalModel model) async {
    await dispose();
    if (model.format != ModelFormat.gguf) {
      throw ArgumentError('Expected GGUF model');
    }
    _engine = await LlamaEngine.load(
      LlamaModel(ModelSource.path(model.location)),
      params: const LlamaCppModelParams(contextSize: 4096, useMmap: true),
    );
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
    final engine = _engine;
    if (engine == null) throw StateError('Load a GGUF model first');
    final messages = [
      for (final turn in history)
        LlamaChatMessage.fromText(
          role: switch (turn.role) {
            'system' => LlamaChatRole.system,
            'assistant' => LlamaChatRole.assistant,
            _ => LlamaChatRole.user,
          },
          text: turn.text,
        ),
    ];
    final clock = Stopwatch()..start();
    int? ttft;
    final buffer = StringBuffer();
    await for (final text
        in engine
            .create(
              messages,
              params: GenerationParams(
                maxTokens: maxTokens,
                temp: temperature,
                seed: seed,
                reusePromptPrefix: reusePromptPrefix,
              ),
            )
            .textDeltas()) {
      if (text.isEmpty) continue;
      ttft ??= clock.elapsedMilliseconds;
      buffer.write(text);
      onDelta?.call(text);
    }
    clock.stop();
    final perf = await engine.getPerformanceContext();
    return GenerationResult(
      buffer.toString(),
      InferenceMetrics(
        totalMs: clock.elapsedMilliseconds,
        ttftMs: ttft,
        decodeTokens: perf?.evalTokens,
        decodeTps: InferenceMetrics.rate(perf?.evalTokens, perf?.evalMs),
        prefillTps: InferenceMetrics.rate(
          perf?.promptEvalTokens,
          perf?.promptEvalMs,
        ),
        source: perf == null ? 'wallclock-only' : 'native-llama-perf',
      ),
    );
  }

  @override
  void cancel() => _engine?.cancelGeneration();

  @override
  Future<void> dispose() async {
    final engine = _engine;
    _engine = null;
    await engine?.dispose();
  }
}
