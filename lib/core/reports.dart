import 'benchmark.dart';
import 'models.dart';

const appVersion = '0.1.2';
const smokeGeneration = {
  'max_tokens': 96,
  'temperature': 0.0,
  'seed': 42,
  'reuse_prompt_prefix': false,
};

Map<String, Object?> _reportHeader({
  required LocalModel model,
  required String device,
  required DateTime startedAt,
  DateTime? exportedAt,
}) => {
  'schema_version': '2.0',
  'app_version': appVersion,
  'date': startedAt.toUtc().toIso8601String(),
  'exported_at': (exportedAt ?? DateTime.now()).toUtc().toIso8601String(),
  'device': device,
  'model': model.toJson(),
  'engine': model.format == ModelFormat.gguf ? 'llama.cpp' : 'MNN',
};

Map<String, Object?> buildEvaluationReport({
  required LocalModel model,
  required String device,
  required String suite,
  required List<EvalResult> results,
  required int plannedCases,
  required String status,
  required DateTime startedAt,
  required DateTime? finishedAt,
  required Map<String, Object?> runnerConfiguration,
  String? error,
  EvalCase? interruptedCase,
  String? partialResponse,
  DateTime? exportedAt,
}) => {
  ..._reportHeader(
    model: model,
    device: device,
    startedAt: startedAt,
    exportedAt: exportedAt,
  ),
  'report_type': 'correctness',
  'suite': suite,
  'status': status,
  'finished_at': finishedAt?.toUtc().toIso8601String(),
  'runtime': runnerConfiguration,
  'error': ?error,
  if (interruptedCase != null)
    'interrupted_case': {
      ...interruptedCase.toJson(),
      'partial_response': partialResponse ?? '',
      'generation': smokeGeneration,
    },
  'generation_parameters_scope': 'requested; consult runtime capabilities',
  'summary': {
    'passed': results.where((result) => result.passed).length,
    'total': results.length,
    'planned_cases': plannedCases,
    'complete': status == 'completed' && results.length == plannedCases,
  },
  'cases': results.map((result) => result.toJson()).toList(),
};

Map<String, Object?> buildBenchmarkReport({
  required LocalModel model,
  required String device,
  required BenchmarkSession session,
  DateTime? exportedAt,
}) => {
  ..._reportHeader(
    model: model,
    device: device,
    startedAt: session.startedAt,
    exportedAt: exportedAt,
  ),
  'report_type': 'performance',
  'suite': 'sustained-generation-v1',
  'benchmark': session.toJson(),
};
