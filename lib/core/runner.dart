import 'models.dart';

typedef TextDelta = void Function(String delta);

abstract class ModelRunner {
  Future<void> load(LocalModel model);
  Future<GenerationResult> generate(
    List<ChatTurn> history, {
    int maxTokens = 128,
    double temperature = 0.8,
    TextDelta? onDelta,
  });
  void cancel();
  Future<void> dispose();
}
