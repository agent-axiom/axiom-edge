import 'package:llamadart/llamadart.dart' hide ModelFormat;

import '../core/models.dart';
import '../core/runner.dart';

class GgufRunner implements ModelRunner {
  LlamaEngine? _engine;

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
              params: GenerationParams(maxTokens: maxTokens, temp: temperature),
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
