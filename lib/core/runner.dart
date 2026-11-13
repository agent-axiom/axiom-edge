import 'models.dart';

typedef TextDelta = void Function(String delta);

abstract class ModelRunner {
  /// Runtime versions, defaults, capabilities and measurement semantics.
  Map<String, Object?> get configuration;

  Future<void> load(LocalModel model);
  Future<GenerationResult> generate(
    List<ChatTurn> history, {
    int maxTokens = 128,
    double temperature = 0.8,
    int? seed,
    bool reusePromptPrefix = true,
    TextDelta? onDelta,
  });
  void cancel();
  Future<void> dispose();
}
