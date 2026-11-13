import 'package:axiom_edge/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('token throughput validates denominator', () {
    expect(InferenceMetrics.rate(128, 1000), 128.0);
    expect(InferenceMetrics.rate(0, 1000), isNull);
    expect(InferenceMetrics.rate(128, 0), isNull);
    expect(InferenceMetrics.rate(null, 200), isNull);
    expect(InferenceMetrics.rate(128, double.nan), isNull);
    expect(InferenceMetrics.rate(128, double.infinity), isNull);
  });

  test('JSON schema probe rejects non-object and malformed JSON', () {
    const testCase = EvalCase(id: 'json', prompt: 'p', kind: 'json_valid');
    expect(evaluate(testCase, '{"ok":true}'), isTrue);
    expect(evaluate(testCase, '[1,2]'), isFalse);
    expect(evaluate(testCase, '```json\n{}\n```'), isFalse);
  });

  test('exact and contains are deterministic', () {
    const exact = EvalCase(id: 'e', prompt: 'p', kind: 'exact', expected: '4');
    const contains = EvalCase(
      id: 'c',
      prompt: 'p',
      kind: 'contains',
      expected: 'satellite',
    );
    expect(evaluate(exact, ' 4\n'), isTrue);
    expect(evaluate(exact, '4.'), isFalse);
    expect(evaluate(contains, 'A SATELLITE flies.'), isTrue);
    const regex = EvalCase(
      id: 'r',
      prompt: 'p',
      kind: 'regex',
      expected: r'^[a-z]+$',
    );
    expect(evaluate(regex, 'hello'), isTrue);
    expect(evaluate(regex, 'HELLO'), isFalse);
  });

  test('registry JSON round trip preserves source and format', () {
    const model = LocalModel(
      id: 'a',
      name: 'pocket',
      format: ModelFormat.gguf,
      location: '/models/pocket.gguf',
      source: 'huggingface',
      sha256: 'abc',
    );
    final copy = LocalModel.fromJson(model.toJson());
    expect(copy.format, ModelFormat.gguf);
    expect(copy.sha256, 'abc');
  });
}
