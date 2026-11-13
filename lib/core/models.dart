import 'dart:convert';

enum ModelFormat { gguf, mnn }

class LocalModel {
  const LocalModel({
    required this.id,
    required this.name,
    required this.format,
    required this.location,
    required this.source,
    this.sha256,
  });

  final String id;
  final String name;
  final ModelFormat format;

  /// GGUF: absolute model path; MNN: imported model ID from mnn_engine.
  final String location;
  final String source;
  final String? sha256;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'format': format.name,
    'location': location,
    'source': source,
    'sha256': sha256,
  };

  factory LocalModel.fromJson(Map<String, dynamic> value) => LocalModel(
    id: value['id'] as String,
    name: value['name'] as String,
    format: ModelFormat.values.byName(value['format'] as String),
    location: value['location'] as String,
    source: value['source'] as String,
    sha256: value['sha256'] as String?,
  );
}

class ChatTurn {
  const ChatTurn(this.role, this.text);
  final String role;
  final String text;

  Map<String, String> toJson() => {'role': role, 'content': text};
}

class InferenceMetrics {
  const InferenceMetrics({
    required this.totalMs,
    required this.source,
    this.ttftMs,
    this.decodeTokens,
    this.decodeTps,
    this.prefillTps,
  });
  final int totalMs;
  final int? ttftMs;
  final int? decodeTokens;
  final double? decodeTps;
  final double? prefillTps;

  /// `native-llama-perf`, `sse-wallclock`, or `wallclock-only`.
  final String source;

  Map<String, Object?> toJson() => {
    'total_ms': totalMs,
    'ttft_ms': ttftMs,
    'decode_tokens': decodeTokens,
    'decode_tokens_per_s': decodeTps,
    'prefill_tokens_per_s': prefillTps,
    'measurement_source': source,
  };

  static double? rate(int? tokens, num? milliseconds) {
    if (tokens == null ||
        tokens <= 0 ||
        milliseconds == null ||
        !milliseconds.isFinite ||
        milliseconds <= 0) {
      return null;
    }
    final value = tokens * 1000.0 / milliseconds;
    return value.isFinite ? value : null;
  }
}

class GenerationResult {
  const GenerationResult(this.text, this.metrics);
  final String text;
  final InferenceMetrics metrics;
}

class EvalCase {
  const EvalCase({
    required this.id,
    required this.prompt,
    required this.kind,
    this.expected,
  });
  final String id;
  final String prompt;
  final String kind;
  final String? expected;

  Map<String, Object?> toJson() => {
    'id': id,
    'prompt': prompt,
    'assertion': {'kind': kind, if (expected != null) 'value': expected},
  };

  factory EvalCase.fromJson(Map<String, dynamic> json) {
    final a = json['assertion'] as Map<String, dynamic>;
    return EvalCase(
      id: json['id'] as String,
      prompt: json['prompt'] as String,
      kind: a['kind'] as String,
      expected: a['value'] as String?,
    );
  }
}

class EvalResult {
  const EvalResult({
    required this.test,
    required this.passed,
    required this.response,
    required this.metrics,
    required this.generation,
  });
  final EvalCase test;
  String get caseId => test.id;
  final bool passed;
  final String response;
  final InferenceMetrics metrics;
  final Map<String, Object?> generation;
  Map<String, Object?> toJson() => {
    'case_id': caseId,
    'prompt': test.prompt,
    'assertion': test.toJson()['assertion'],
    'generation': generation,
    'passed': passed,
    'response': response,
    'metrics': metrics.toJson(),
  };
}

bool evaluate(EvalCase test, String output) {
  final candidate = output.trim();
  switch (test.kind) {
    case 'exact':
      return candidate == test.expected;
    case 'contains':
      return candidate.toLowerCase().contains(
            (test.expected ?? '').toLowerCase(),
          ) &&
          (test.expected?.isNotEmpty ?? false);
    case 'regex':
      final expression = test.expected;
      if (expression == null) {
        throw ArgumentError('Regex expected value is missing');
      }
      return RegExp(expression).hasMatch(candidate);
    case 'json_valid':
      try {
        final data = jsonDecode(candidate);
        return data is Map<String, dynamic>;
      } on FormatException {
        return false;
      }
    default:
      throw ArgumentError.value(test.kind, 'kind', 'Unsupported assertion');
  }
}
