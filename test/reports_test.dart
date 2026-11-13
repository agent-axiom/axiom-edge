import 'dart:convert';

import 'package:axiom_edge/core/benchmark.dart';
import 'package:axiom_edge/core/models.dart';
import 'package:axiom_edge/core/reports.dart';
import 'package:flutter_test/flutter_test.dart';

const model = LocalModel(
  id: 'fixture',
  name: 'Test model',
  format: ModelFormat.gguf,
  location: '/test/model.gguf',
  source: 'fixture',
  sha256: 'test-digest',
);

void main() {
  final started = DateTime.utc(2026, 11, 13, 4);
  final exported = started.add(const Duration(hours: 1));
  const probe = EvalCase(
    id: 'literal-answer',
    prompt: 'Answer with one digit only: what is 2 + 2?',
    kind: 'exact',
    expected: '4',
  );

  test('failed answer preserves replay inputs and original run time', () {
    final report = buildEvaluationReport(
      model: model,
      device: 'test-device',
      suite: 'pocket-smoke-v1',
      results: const [
        EvalResult(
          test: probe,
          passed: false,
          response: '1',
          metrics: InferenceMetrics(totalMs: 200, source: 'fixture'),
          generation: smokeGeneration,
        ),
      ],
      plannedCases: 3,
      status: 'cancelled',
      startedAt: started,
      finishedAt: started.add(const Duration(seconds: 1)),
      runnerConfiguration: const {
        'supported_controls': {'seed': true},
      },
      exportedAt: exported,
    );
    final decoded = jsonDecode(jsonEncode(report)) as Map<String, dynamic>;
    expect(decoded['schema_version'], '2.0');
    expect(decoded['date'], started.toIso8601String());
    expect(decoded['exported_at'], exported.toIso8601String());
    expect(decoded['summary']['complete'], false);
    expect(decoded['summary']['planned_cases'], 3);
    expect(decoded['cases'][0]['prompt'], probe.prompt);
    expect(decoded['cases'][0]['assertion'], {'kind': 'exact', 'value': '4'});
    expect(decoded['cases'][0]['generation']['seed'], 42);
    expect(decoded['cases'][0]['response'], '1');
    expect(decoded['model']['sha256'], 'test-digest');
  });

  test('engine error preserves interrupted case and partial text', () {
    final report = buildEvaluationReport(
      model: model,
      device: 'test-device',
      suite: 'pocket-smoke-v1',
      results: [],
      plannedCases: 3,
      status: 'error',
      startedAt: started,
      finishedAt: exported,
      runnerConfiguration: {},
      error: 'backend disconnected',
      interruptedCase: probe,
      partialResponse: 'The answer',
    );
    final decoded = jsonDecode(jsonEncode(report)) as Map<String, dynamic>;
    expect(decoded['error'], 'backend disconnected');
    expect(decoded['interrupted_case']['prompt'], probe.prompt);
    expect(decoded['interrupted_case']['partial_response'], 'The answer');
    expect(decoded['interrupted_case']['generation']['max_tokens'], 96);
    expect(decoded['summary']['passed'], 0);
    expect(decoded['summary']['complete'], false);
  });

  test(
    'performance report retains incomplete session and model provenance',
    () {
      final session = BenchmarkSession(
        config: const BenchmarkConfig(),
        samples: [],
        startedAt: started,
        finishedAt: exported,
        complete: false,
        cancelled: true,
        runnerConfiguration: const {'runtime_package_version': 'test'},
      );
      final report = buildBenchmarkReport(
        model: model,
        device: 'test-device',
        session: session,
        exportedAt: exported,
      );
      final decoded = jsonDecode(jsonEncode(report)) as Map<String, dynamic>;
      expect(decoded['report_type'], 'performance');
      expect(decoded['benchmark']['complete'], false);
      expect(decoded['benchmark']['cancelled'], true);
      expect(decoded['benchmark']['planned_runs'], 7);
      expect(
        decoded['benchmark']['runner_configuration']['runtime_package_version'],
        'test',
      );
      expect(decoded['model']['sha256'], 'test-digest');
    },
  );
}
