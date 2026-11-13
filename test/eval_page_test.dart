import 'package:axiom_edge/core/benchmark.dart';
import 'package:axiom_edge/core/lab_state.dart';
import 'package:axiom_edge/core/models.dart';
import 'package:axiom_edge/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

BenchmarkSession sessionWith({int tokens = 1, bool cancelled = false}) {
  final start = DateTime.utc(2026, 11, 13);
  final config = BenchmarkConfig(warmupRuns: cancelled ? 0 : 2);
  return BenchmarkSession(
    config: config,
    startedAt: start,
    finishedAt: start.add(const Duration(seconds: 7)),
    complete: !cancelled,
    cancelled: cancelled,
    samples: [
      for (var i = 0; i < (cancelled ? 1 : config.totalRuns); i++)
        BenchmarkSample(
          phase: i >= config.warmupRuns ? 'measured' : 'warmup',
          index: i < config.warmupRuns ? i + 1 : i - config.warmupRuns + 1,
          startedAt: start,
          status: cancelled ? 'cancelled' : 'completed',
          prompt: config.prompt,
          generation: config.generation,
          response: '1',
          metrics: InferenceMetrics(
            totalMs: 200,
            ttftMs: 100,
            decodeTokens: tokens,
            decodeTps: 999,
            source: 'native-llama-perf',
          ),
        ),
    ],
  );
}

Future<void> mountPage(WidgetTester tester, LabState state) async {
  await tester.binding.setSurfaceSize(const Size(320, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(1.5)),
        child: child!,
      ),
      home: Scaffold(body: EvalPage(state)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('controls and exact expected answer fit a narrow enlarged page', (
    tester,
  ) async {
    final state = LabState()
      ..evalStartedAt = DateTime.utc(2026, 11, 13)
      ..evalStatus = 'completed'
      ..evals = [
        const EvalResult(
          test: EvalCase(
            id: 'literal-answer',
            prompt: 'Answer with one digit only: what is 2 + 2?',
            kind: 'exact',
            expected: '4',
          ),
          passed: false,
          response: '1',
          metrics: InferenceMetrics(totalMs: 242, source: 'native-llama-perf'),
          generation: {'max_tokens': 96, 'temperature': 0},
        ),
      ];
    await mountPage(tester, state);
    expect(find.text('Замер скорости'), findsOneWidget);
    expect(find.text('Начать замер'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.byKey(const Key('eval-literal-answer')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('eval-literal-answer')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Ожидается: 4'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Ожидается: 4'), findsOneWidget);
    expect(find.text('Ответ: 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short generations do not produce an aggregate speed', (
    tester,
  ) async {
    final state = LabState()..benchmark = sessionWith();
    await mountPage(tester, state);
    final message = find.text(
      'Скорость не рассчитана: нет подходящих длинных ответов с метриками.',
    );
    await tester.scrollUntilVisible(
      message,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(message, findsOneWidget);
    expect(
      find.byKey(const Key('aggregate-decode-native-llama-perf')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancelled samples remain incomplete and out of the speed summary',
    (tester) async {
      final state = LabState()
        ..benchmark = sessionWith(tokens: 256, cancelled: true);
      await mountPage(tester, state);
      final message = find.text('Замер остановлен: результаты неполные.');
      await tester.scrollUntilVisible(
        message,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(message, findsOneWidget);
      expect(
        find.byKey(const Key('aggregate-decode-native-llama-perf')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
