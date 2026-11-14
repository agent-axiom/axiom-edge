import 'dart:async';
import 'dart:convert';

import 'package:axiom_edge/core/benchmark.dart';
import 'package:axiom_edge/core/lab_state.dart';
import 'package:axiom_edge/core/models.dart';
import 'package:axiom_edge/core/reports.dart';
import 'package:axiom_edge/core/runner.dart';
import 'package:flutter_test/flutter_test.dart';

const _model = LocalModel(
  id: 'test-model',
  name: 'Test model',
  format: ModelFormat.gguf,
  location: '/test/model.gguf',
  source: 'test-fixture',
);

const _metrics = InferenceMetrics(
  totalMs: 100,
  source: 'native-llama-perf',
  ttftMs: 10,
  decodeTokens: 256,
  decodeTps: 40,
  prefillTps: 120,
);

class _StateRunner implements ModelRunner {
  _StateRunner(this.respond, {this.onCancel});

  final Future<GenerationResult> Function(
    int call,
    List<ChatTurn> history,
    TextDelta? onDelta,
  )
  respond;
  final void Function()? onCancel;
  final calls = <Map<String, Object?>>[];
  LocalModel? loaded;
  var cancelled = false;
  var disposed = false;

  @override
  Map<String, Object?> get configuration => {
    'engine': 'test-runner',
    'runtime_version': 'test-version',
  };

  @override
  Future<void> load(LocalModel model) async {
    loaded = model;
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
    calls.add({
      'messages': history.map((turn) => turn.toJson()).toList(),
      'max_tokens': maxTokens,
      'temperature': temperature,
      'seed': seed,
      'reuse_prompt_prefix': reusePromptPrefix,
    });
    return respond(calls.length, history, onDelta);
  }

  @override
  void cancel() {
    cancelled = true;
    onCancel?.call();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

Future<LabState> _loadedState(_StateRunner runner) async {
  final state = LabState(
    runnerFactory: (format) {
      expect(format, ModelFormat.gguf);
      return runner;
    },
  );
  addTearDown(state.dispose);
  await state.selectModel(_model);
  expect(runner.loaded, same(_model));
  expect(state.isReady, isTrue);
  expect(state.busy, isFalse);
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'LabState runs the full benchmark and restores lifecycle flags',
    () async {
      final runner = _StateRunner(
        (_, _, _) async =>
            const GenerationResult('Satellite details', _metrics),
      );
      final state = await _loadedState(runner);
      var observedRunning = false;
      state.addListener(() {
        observedRunning = observedRunning || (state.busy && state.generating);
      });

      await state.runBenchmark();

      expect(observedRunning, isTrue);
      expect(state.busy, isFalse);
      expect(state.generating, isFalse);
      expect(state.progress, isNull);
      expect(state.error, isNull);
      expect(state.status, 'Замер завершён');
      expect(runner.calls, hasLength(7));
      for (final call in runner.calls) {
        expect(call['max_tokens'], 256);
        expect(call['temperature'], 0);
        expect(call['seed'], 42);
        expect(call['reuse_prompt_prefix'], isFalse);
        expect(call['messages'], [
          {'role': 'user', 'content': BenchmarkConfig.defaultPrompt},
        ]);
      }
      final session = state.benchmark!;
      expect(session.complete, isTrue);
      expect(session.cancelled, isFalse);
      expect(session.samples, hasLength(7));
      expect(state.benchmarkSamples, session.samples);
      expect(session.runnerConfiguration['runtime_version'], 'test-version');
      expect(
        session.summaryBySource['native-llama-perf']!['completed_count'],
        5,
      );
      expect(state.lastMetrics, same(_metrics));
    },
  );

  test(
    'LabState cancellation retains partial text without completed timing',
    () async {
      final measuredStarted = Completer<void>();
      final pending = Completer<GenerationResult>();
      final runner = _StateRunner(
        (call, _, onDelta) async {
          if (call <= 2) {
            return const GenerationResult('Warmup', _metrics);
          }
          onDelta?.call('Partial measured response');
          measuredStarted.complete();
          return pending.future;
        },
        onCancel: () =>
            pending.completeError(StateError('generation cancelled')),
      );
      final state = await _loadedState(runner);
      final running = state.runBenchmark();
      await measuredStarted.future;
      expect(state.busy, isTrue);
      expect(state.generating, isTrue);

      state.cancel();
      await running;

      expect(runner.cancelled, isTrue);
      expect(runner.calls, hasLength(3));
      expect(state.busy, isFalse);
      expect(state.generating, isFalse);
      expect(state.status, 'Замер остановлен');
      final session = state.benchmark!;
      expect(session.complete, isFalse);
      expect(session.cancelled, isTrue);
      expect(session.samples, hasLength(3));
      final interrupted = session.samples.last;
      expect(interrupted.phase, 'measured');
      expect(interrupted.status, 'cancelled');
      expect(interrupted.response, 'Partial measured response');
      expect(interrupted.metrics, isNull);
      final summary = session.summaryBySource['unavailable']!;
      expect(summary['completed_count'], 0);
      expect(summary['cancelled_count'], 1);
      expect(summary['throughput_eligible_count'], 0);
      final latency = summary['total_ms']! as Map<String, Object?>;
      expect(latency['count'], 0);
    },
  );

  test(
    'smoke suite preserves real prompts, assertions and generation settings',
    () async {
      final responses = ['4', '{"success":true}', 'A satellite orbits Earth.'];
      final runner = _StateRunner(
        (call, _, _) async => GenerationResult(responses[call - 1], _metrics),
      );
      final state = await _loadedState(runner);

      await state.runSmoke();

      expect(state.busy, isFalse);
      expect(state.generating, isFalse);
      expect(state.error, isNull);
      expect(state.evalStatus, 'completed');
      expect(state.suiteName, 'pocket-smoke-v2');
      expect(state.plannedEvalCases, 3);
      expect(state.evals, hasLength(3));
      expect(state.evals.every((result) => result.passed), isTrue);
      expect(state.evalStartedAt, isNotNull);
      expect(state.evalFinishedAt, isNotNull);
      final report = buildEvaluationReport(
        model: _model,
        device: state.device,
        suite: state.suiteName,
        results: state.evals,
        plannedCases: state.plannedEvalCases,
        status: state.evalStatus,
        startedAt: state.evalStartedAt!,
        finishedAt: state.evalFinishedAt,
        runnerConfiguration: runner.configuration,
      );
      final exported = jsonDecode(jsonEncode(report)) as Map<String, dynamic>;
      final cases = (exported['cases'] as List).cast<Map<String, dynamic>>();
      expect(cases, hasLength(responses.length));
      expect(runner.calls, hasLength(cases.length));
      final literal = cases.first;
      expect(literal['case_id'], 'literal-answer');
      expect(literal['prompt'], 'Answer with one digit only: what is 2 + 2?');
      expect(literal['assertion'], {'kind': 'exact', 'value': '4'});
      const expectedGeneration = {
        'max_tokens': 96,
        'temperature': 0.0,
        'seed': 42,
        'reuse_prompt_prefix': false,
      };
      for (final (index, item) in cases.indexed) {
        expect(item['response'], responses[index]);
        expect(item['generation'], expectedGeneration);
        expect(runner.calls[index], {
          'messages': [
            {'role': 'user', 'content': item['prompt']},
          ],
          ...expectedGeneration,
        });
      }
    },
  );

  test(
    'smoke failure retains completed cases and restores lifecycle flags',
    () async {
      final runner = _StateRunner((call, _, onDelta) async {
        if (call == 1) return const GenerationResult('4', _metrics);
        onDelta?.call('{"success":');
        throw StateError('smoke engine failure');
      });
      final state = await _loadedState(runner);

      await state.runSmoke();

      expect(runner.calls, hasLength(2));
      expect(state.busy, isFalse);
      expect(state.generating, isFalse);
      expect(state.progress, isNull);
      expect(state.evalStatus, 'error');
      expect(state.error, contains('smoke engine failure'));
      expect(state.status, 'Ошибка');
      expect(state.plannedEvalCases, 3);
      expect(state.evals, hasLength(1));
      expect(state.evals.single.caseId, 'literal-answer');
      expect(state.evals.single.passed, isTrue);
      expect(state.evalFinishedAt, isNotNull);
    },
  );

  test(
    'smoke cancellation throwing from the engine remains cancelled',
    () async {
      final started = Completer<void>();
      final pending = Completer<GenerationResult>();
      final runner = _StateRunner(
        (_, _, onDelta) async {
          onDelta?.call('4');
          started.complete();
          return pending.future;
        },
        onCancel: () =>
            pending.completeError(StateError('generation cancelled')),
      );
      final state = await _loadedState(runner);
      final running = state.runSmoke();
      await started.future;
      expect(state.busy, isTrue);
      expect(state.generating, isTrue);

      state.cancel();
      await running;

      expect(runner.cancelled, isTrue);
      expect(runner.calls, hasLength(1));
      expect(state.evalStatus, 'cancelled');
      expect(state.status, isNot('Ошибка'));
      expect(state.error, isNull);
      expect(state.evals, isEmpty);
      expect(state.plannedEvalCases, 3);
      expect(state.evalFinishedAt, isNotNull);
      expect(state.busy, isFalse);
      expect(state.generating, isFalse);
      expect(state.progress, isNull);
    },
  );
}
