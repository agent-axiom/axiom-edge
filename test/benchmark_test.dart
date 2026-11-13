import 'dart:convert';

import 'package:axiom_edge/core/benchmark.dart';
import 'package:axiom_edge/core/models.dart';
import 'package:axiom_edge/core/runner.dart';
import 'package:flutter_test/flutter_test.dart';

GenerationResult answer({
  int? tokens = 256,
  double? decodeTps = 40,
  double? prefillTps = 120,
  int? ttftMs = 10,
  int totalMs = 100,
  String source = 'native-llama-perf',
}) => GenerationResult(
  'A detailed satellite explanation.',
  InferenceMetrics(
    totalMs: totalMs,
    source: source,
    ttftMs: ttftMs,
    decodeTokens: tokens,
    decodeTps: decodeTps,
    prefillTps: prefillTps,
  ),
);

class FakeRunner implements ModelRunner {
  FakeRunner(this.respond, {this.stream});

  final Future<GenerationResult> Function(int call) respond;
  final void Function(TextDelta? onDelta)? stream;
  final calls = <Map<String, Object?>>[];

  @override
  Map<String, Object?> get configuration => {
    'engine': 'test-runner',
    'sampling': {'top_k': 40},
  };

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
      'messages': history.map((message) => message.toJson()).toList(),
      'max_tokens': maxTokens,
      'temperature': temperature,
      'seed': seed,
      'reuse_prompt_prefix': reusePromptPrefix,
    });
    stream?.call(onDelta);
    return respond(calls.length);
  }

  @override
  Future<void> load(LocalModel model) async {}

  @override
  void cancel() {}

  @override
  Future<void> dispose() async {}
}

Map<String, Object?> distribution(Map<String, Object?> source, String metric) =>
    source[metric]! as Map<String, Object?>;

void main() {
  test(
    'protocol runs two warmups then five independent measured generations',
    () async {
      final runner = FakeRunner(
        (call) async =>
            answer(decodeTps: call <= 2 ? 999 : ((call - 2) * 10).toDouble()),
      );
      final phases = <String>[];
      final progress = <int>[];
      final clock = DateTime.utc(2026, 11, 13);
      final session = await BenchmarkService(runner, now: () => clock).run(
        onProgress: (phase, index, total) => phases.add('$phase:$index/$total'),
        onSample: (_, completed, total) {
          progress.add(completed);
          expect(total, 7);
        },
      );

      expect(session.complete, isTrue);
      expect(session.cancelled, isFalse);
      expect(runner.calls, hasLength(7));
      expect(session.samples, hasLength(7));
      expect(progress, [1, 2, 3, 4, 5, 6, 7]);
      expect(phases.first, 'warmup:1/2');
      expect(phases[2], 'measured:1/5');
      expect(phases.last, 'measured:5/5');
      for (final call in runner.calls) {
        expect(call['max_tokens'], 256);
        expect(call['temperature'], 0);
        expect(call['seed'], 42);
        expect(call['reuse_prompt_prefix'], isFalse);
        expect(call['messages'], [
          {'role': 'user', 'content': BenchmarkConfig.defaultPrompt},
        ]);
      }
      final summary = session.summaryBySource['native-llama-perf']!;
      expect(summary['completed_count'], 5);
      expect(summary['throughput_eligible_count'], 5);
      expect(distribution(summary, 'decode_tokens_per_s'), {
        'count': 5,
        'missing_count': 0,
        'invalid_count': 0,
        'min': 10.0,
        'max': 50.0,
        'median': 30.0,
        'p90': 50.0,
      });
      final payload = jsonDecode(jsonEncode(session.toJson())) as Map;
      expect(payload['recorded_runs'], 7);
      expect(payload['planned_runs'], 7);
      expect(payload['runner_configuration']['engine'], 'test-runner');
      final samples = payload['samples'] as List;
      expect(samples.first['started_at'], clock.toIso8601String());
      expect(samples.first['prompt'], BenchmarkConfig.defaultPrompt);
      expect(samples.first['generation']['seed'], 42);
      expect(samples.first['response'], 'A detailed satellite explanation.');
      expect(samples.first['phase'], 'warmup');
    },
  );

  test(
    'short, missing, invalid and incomparable throughput remain explicit',
    () async {
      final results = [
        answer(tokens: 1, decodeTps: 1000),
        answer(tokens: null, decodeTps: 999),
        answer(tokens: 128, decodeTps: double.nan, prefillTps: -1),
        answer(tokens: 128, decodeTps: 40, ttftMs: null),
        answer(
          tokens: 128,
          decodeTps: 20,
          prefillTps: null,
          source: 'sse-wallclock',
        ),
        answer(
          tokens: null,
          decodeTps: null,
          prefillTps: null,
          source: 'wallclock-only',
        ),
      ];
      final runner = FakeRunner((call) async => results[call - 1]);
      final session = await BenchmarkService(
        runner,
      ).run(config: const BenchmarkConfig(warmupRuns: 0, measuredRuns: 6));
      final summary = session.summaryBySource;
      expect(
        summary.keys,
        unorderedEquals([
          'native-llama-perf',
          'sse-wallclock',
          'wallclock-only',
        ]),
      );
      final native = summary['native-llama-perf']!;
      expect(native['sample_count'], 4);
      expect(native['short_output_count'], 1);
      expect(native['unknown_decode_tokens_count'], 1);
      expect(native['throughput_eligible_count'], 2);
      expect(native['throughput_excluded_count'], 2);
      expect(distribution(native, 'decode_tokens_per_s')['count'], 1);
      expect(distribution(native, 'decode_tokens_per_s')['invalid_count'], 1);
      expect(distribution(native, 'decode_tokens_per_s')['median'], 40);
      expect(distribution(native, 'prefill_tokens_per_s')['invalid_count'], 1);
      expect(distribution(native, 'ttft_ms')['count'], 3);
      expect(distribution(native, 'ttft_ms')['missing_count'], 1);
      expect(distribution(native, 'total_ms')['count'], 4);
      expect(
        distribution(
          summary['sse-wallclock']!,
          'decode_tokens_per_s',
        )['median'],
        20,
      );
      expect(
        distribution(
          summary['wallclock-only']!,
          'decode_tokens_per_s',
        )['median'],
        isNull,
      );
      final payload = jsonDecode(jsonEncode(session.toJson())) as Map;
      final sample = (payload['samples'] as List)[2];
      expect(sample['metrics']['decode_tokens_per_s'], isNull);
      expect(sample['non_finite_metric_fields'], ['decode_tokens_per_s']);
    },
  );

  test('even median and nearest-rank p90 use measured runs only', () async {
    final values = [2.0, 4.0, 8.0, 10.0];
    final runner = FakeRunner(
      (call) async => answer(decodeTps: values[call - 1]),
    );
    final session = await BenchmarkService(
      runner,
    ).run(config: const BenchmarkConfig(warmupRuns: 0, measuredRuns: 4));
    final stats = distribution(
      session.summaryBySource['native-llama-perf']!,
      'decode_tokens_per_s',
    );
    expect(stats['median'], 6);
    expect(stats['p90'], 10);
  });

  test(
    'cancellation before first generation creates an incomplete empty session',
    () async {
      final runner = FakeRunner((_) async => answer());
      final session = await BenchmarkService(
        runner,
      ).run(isCancelled: () => true);
      expect(runner.calls, isEmpty);
      expect(session.samples, isEmpty);
      expect(session.summaryBySource, isEmpty);
      expect(session.complete, isFalse);
      expect(session.cancelled, isTrue);
    },
  );

  test(
    'cancelled generation keeps raw metrics and never enters aggregates',
    () async {
      var cancelled = false;
      final runner = FakeRunner((_) async {
        cancelled = true;
        return answer();
      });
      final session = await BenchmarkService(runner).run(
        config: const BenchmarkConfig(warmupRuns: 0),
        isCancelled: () => cancelled,
      );
      expect(runner.calls, hasLength(1));
      expect(session.complete, isFalse);
      expect(session.cancelled, isTrue);
      expect(session.samples.single.status, 'cancelled');
      expect(session.samples.single.metrics!.decodeTokens, 256);
      final summary = session.summaryBySource['native-llama-perf']!;
      expect(summary['cancelled_count'], 1);
      expect(summary['completed_count'], 0);
      expect(distribution(summary, 'total_ms')['count'], 0);
      expect(distribution(summary, 'decode_tokens_per_s')['count'], 0);
    },
  );

  test('cancellation after warmup prevents measured generations', () async {
    var cancelled = false;
    final runner = FakeRunner((_) async => answer());
    final session = await BenchmarkService(runner).run(
      isCancelled: () => cancelled,
      onSample: (_, completed, total) => cancelled = true,
    );
    expect(runner.calls, hasLength(1));
    expect(session.samples.single.phase, 'warmup');
    expect(session.summaryBySource, isEmpty);
    expect(session.complete, isFalse);
    expect(session.cancelled, isTrue);
  });

  test(
    'engine failure is recorded and ends the session without fabricated timing',
    () async {
      final runner = FakeRunner(
        (_) async => throw StateError('native failure'),
      );
      final session = await BenchmarkService(
        runner,
      ).run(config: const BenchmarkConfig(warmupRuns: 0));
      expect(runner.calls, hasLength(1));
      expect(session.complete, isFalse);
      expect(session.cancelled, isFalse);
      expect(session.samples.single.status, 'error');
      expect(session.samples.single.error, contains('native failure'));
      expect(session.samples.single.metrics, isNull);
      final summary = session.summaryBySource['unavailable']!;
      expect(summary['error_count'], 1);
      expect(distribution(summary, 'total_ms')['median'], isNull);
      expect(() => jsonEncode(session.toJson()), returnsNormally);
    },
  );

  test('streamed text is preserved when generation throws', () async {
    final runner = FakeRunner(
      (_) async => throw StateError('stream interrupted'),
      stream: (onDelta) {
        onDelta?.call('A partial ');
        onDelta?.call('explanation.');
      },
    );
    final session = await BenchmarkService(
      runner,
    ).run(config: const BenchmarkConfig(warmupRuns: 0));
    expect(session.complete, isFalse);
    expect(session.samples.single.status, 'error');
    expect(session.samples.single.response, 'A partial explanation.');
    expect(session.samples.single.metrics, isNull);
    final exported = session.samples.single.toJson();
    expect(exported['response'], 'A partial explanation.');
    expect(exported['error'], contains('stream interrupted'));
  });

  test(
    'streamed text is preserved on cancellation throwing from engine',
    () async {
      var cancelled = false;
      final runner = FakeRunner(
        (_) async => throw StateError('generation cancelled'),
        stream: (onDelta) {
          onDelta?.call('Partial before stop');
          cancelled = true;
        },
      );
      final session = await BenchmarkService(runner).run(
        config: const BenchmarkConfig(warmupRuns: 0),
        isCancelled: () => cancelled,
      );
      expect(session.complete, isFalse);
      expect(session.cancelled, isTrue);
      expect(session.samples.single.status, 'cancelled');
      expect(session.samples.single.response, 'Partial before stop');
      expect(session.samples.single.metrics, isNull);
    },
  );

  test('cancellation in onProgress prevents the next generation', () async {
    var cancelled = false;
    final runner = FakeRunner((_) async => answer());
    final session = await BenchmarkService(runner).run(
      isCancelled: () => cancelled,
      onProgress: (_, index, total) => cancelled = true,
    );
    expect(runner.calls, isEmpty);
    expect(session.samples, isEmpty);
    expect(session.cancelled, isTrue);
    expect(session.complete, isFalse);
  });

  test('invalid settings fail before invoking the engine', () async {
    final runner = FakeRunner((_) async => answer());
    for (final config in [
      const BenchmarkConfig(warmupRuns: -1),
      const BenchmarkConfig(measuredRuns: 0),
      const BenchmarkConfig(maxTokens: 0),
      const BenchmarkConfig(minDecodeTokens: 257),
      const BenchmarkConfig(temperature: double.infinity),
      const BenchmarkConfig(prompt: ' '),
    ]) {
      await expectLater(
        BenchmarkService(runner).run(config: config),
        throwsArgumentError,
      );
    }
    expect(runner.calls, isEmpty);
  });
}
