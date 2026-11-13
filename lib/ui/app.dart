import 'dart:io';
import 'package:flutter/material.dart';

import '../core/benchmark.dart';
import '../core/lab_state.dart';
import '../core/models.dart';

class AxiomEdgeApp extends StatefulWidget {
  const AxiomEdgeApp({super.key, required this.state});
  final LabState state;

  @override
  State<AxiomEdgeApp> createState() => _AxiomEdgeAppState();
}

class _AxiomEdgeAppState extends State<AxiomEdgeApp> {
  @override
  void dispose() {
    widget.state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Axiom Edge',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF33D6A6),
        scaffoldBackgroundColor: const Color(0xFF0B1015),
      ),
      home: Home(state: widget.state),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key, required this.state});
  final LabState state;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int page = 0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final s = widget.state;
        return Scaffold(
          appBar: AppBar(
            title: const Text(
              'AXIOM / EDGE',
              style: TextStyle(letterSpacing: 1.7, fontWeight: FontWeight.w700),
            ),
            actions: [
              if (s.generating)
                IconButton(
                  tooltip: 'Остановить генерацию',
                  icon: const Icon(Icons.stop_circle_outlined),
                  onPressed: s.cancel,
                ),
            ],
          ),
          body: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                color: const Color(0xFF131D25),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.active == null
                          ? 'Движок не загружен'
                          : '${s.active!.name} · ${s.active!.format.name.toUpperCase()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      s.error ?? s.status,
                      style: TextStyle(
                        color: s.error == null
                            ? Colors.white70
                            : Colors.redAccent,
                        fontSize: 12,
                      ),
                    ),
                    if (s.progress != null) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: s.progress),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: IndexedStack(
                  index: page,
                  children: [
                    ModelPage(s, onSelected: () => setState(() => page = 1)),
                    ChatPage(s),
                    EvalPage(s),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: page,
            onDestinationSelected: (i) => setState(() => page = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.memory_outlined),
                selectedIcon: Icon(Icons.memory),
                label: 'Модели',
              ),
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble),
                label: 'Чат',
              ),
              NavigationDestination(
                icon: Icon(Icons.monitor_heart_outlined),
                selectedIcon: Icon(Icons.monitor_heart),
                label: 'Проверки',
              ),
            ],
          ),
        );
      },
    );
  }
}

class ModelPage extends StatelessWidget {
  const ModelPage(this.state, {super.key, required this.onSelected});
  final LabState state;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final canAct = !state.busy;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Найти и загрузить',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Модели хранятся на телефоне. После загрузки интернет не нужен.',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 16),
        _ModelOffer(
          icon: Icons.flash_on_outlined,
          title: 'MNN-Pocket-0.3B · Q4_1',
          subtitle: 'GGUF · ~192 MB · Android + iOS',
          onDownload: canAct ? state.downloadGguf : null,
        ),
        const SizedBox(height: 10),
        _ModelOffer(
          icon: Icons.developer_board_outlined,
          title: 'MNN-Pocket-0.3B · INT4',
          subtitle:
              'MNN · ~173 MB · Android ARM64 · experimental compatibility',
          onDownload: canAct && Platform.isAndroid ? state.downloadMnn : null,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: canAct ? state.importGguf : null,
              icon: const Icon(Icons.file_open),
              label: const Text('Импорт GGUF'),
            ),
            if (Platform.isAndroid)
              OutlinedButton.icon(
                onPressed: canAct ? state.importMnn : null,
                icon: const Icon(Icons.folder_open),
                label: const Text('Импорт папки MNN'),
              ),
          ],
        ),
        const SizedBox(height: 24),
        const Text(
          'На устройстве',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        if (state.models.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'Модели ещё не загружены',
              style: TextStyle(color: Colors.white60),
            ),
          ),
        for (final model in state.models)
          Card(
            child: ListTile(
              leading: Icon(
                model.format == ModelFormat.gguf
                    ? Icons.memory
                    : Icons.layers_outlined,
              ),
              title: Text(
                model.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(model.format.name.toUpperCase()),
              trailing: state.active?.id == model.id
                  ? const Icon(Icons.check_circle, color: Color(0xFF33D6A6))
                  : const Icon(Icons.play_circle_outline),
              onTap: canAct
                  ? () async {
                      await state.selectModel(model);
                      if (state.isReady) onSelected();
                    }
                  : null,
            ),
          ),
        const SizedBox(height: 24),
        Text(
          state.device,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 6),
        const Text(
          'Внимание: новая сборка Pocket MNN может не загрузиться из-за несовместимости версии MNN.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }
}

class _ModelOffer extends StatelessWidget {
  const _ModelOffer({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.onDownload,
  });
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: const Color(0xFF33D6A6)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: onDownload,
                icon: const Icon(Icons.download),
                label: const Text('Скачать'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage(this.state, {super.key});
  final LabState state;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final input = TextEditingController();
  final scroll = ScrollController();

  @override
  void dispose() {
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty) return;
    input.clear();
    await widget.state.send(text);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    if (!s.isReady) {
      return const Center(
        child: Text('Сначала загрузи модель во вкладке «Модели»'),
      );
    }
    return Column(
      children: [
        if (s.lastMetrics != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Первый текст: ${s.lastMetrics!.ttftMs ?? '—'} мс  •  ${s.lastMetrics!.source == 'sse-wallclock' ? 'SSE, всё время' : 'Генерация'}: ${s.lastMetrics!.decodeTps?.toStringAsFixed(1) ?? '—'} ток/с  •  Всего: ${s.lastMetrics!.totalMs} мс',
              style: const TextStyle(fontSize: 12, color: Color(0xFF33D6A6)),
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: scroll,
            padding: const EdgeInsets.all(12),
            itemCount: s.chat.length,
            itemBuilder: (context, i) {
              final turn = s.chat[i];
              final user = turn.role == 'user';
              return Align(
                alignment: user ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.sizeOf(context).width * .86,
                  ),
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: user
                        ? const Color(0xFF134F43)
                        : const Color(0xFF1E2A33),
                  ),
                  child: SelectableText(turn.text.isEmpty ? '…' : turn.text),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 18),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: input,
                  enabled: !s.busy,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Сообщение локальной модели',
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filled(
                onPressed: s.busy ? null : _send,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class EvalPage extends StatelessWidget {
  const EvalPage(this.state, {super.key});
  final LabState state;

  @override
  Widget build(BuildContext context) {
    final session = state.benchmark;
    final samples = state.benchmarkSamples.isNotEmpty
        ? state.benchmarkSamples
        : session?.samples ?? const <BenchmarkSample>[];
    const config = BenchmarkConfig();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Замер скорости',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          '${config.warmupRuns} прогрева + ${config.measuredRuns} повторов. '
          'Лимит ответа — ${config.maxTokens} токенов. '
          'В сводку скорости входят ответы от ${config.minDecodeTokens} токенов.',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 8),
        const Text(
          'Модель остаётся загруженной. Прогрев не входит в сводку. '
          'Первый текст — время до первого фрагмента в приложении; '
          'он может содержать несколько токенов.',
          style: TextStyle(fontSize: 12, color: Colors.white60),
        ),
        if (state.active?.format == ModelFormat.mnn) ...[
          const SizedBox(height: 8),
          const Text(
            'MNN: скорость учитывает всё время запроса. Это оценка по SSE, '
            'её нельзя напрямую сравнивать с нативной скоростью llama.cpp. '
            'Seed и повторное использование префикса здесь не управляются.',
            style: TextStyle(fontSize: 12, color: Colors.amberAccent),
          ),
        ],
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: state.isReady && !state.busy
                  ? state.runBenchmark
                  : null,
              icon: const Icon(Icons.speed),
              label: const Text('Начать замер'),
            ),
            _ExportButton(
              state: state,
              performance: true,
              enabled: session != null && !state.busy,
              label: 'JSON замера',
            ),
          ],
        ),
        if (session != null) ...[
          const SizedBox(height: 14),
          Text(
            session.cancelled
                ? 'Замер остановлен: результаты неполные.'
                : session.complete
                ? 'Замер завершён.'
                : 'Замер прерван: результаты неполные.',
            style: TextStyle(
              color: session.complete
                  ? const Color(0xFF33D6A6)
                  : Colors.orangeAccent,
            ),
          ),
          Text(
            'Выполнено ${session.samples.length} из ${session.config.totalRuns} запусков, включая прогрев.',
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
          for (final group in session.summaryBySource.entries)
            _BenchmarkSummary(source: group.key, values: group.value),
          const SizedBox(height: 6),
          const Text(
            'Задержки включают все завершённые повторы, в том числе короткие. '
            'При пяти значениях p90 совпадает с максимумом.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
        if (samples.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Отдельные запуски'),
          for (final sample in samples) _BenchmarkSampleCard(sample),
        ],
        const SizedBox(height: 28),
        const Divider(),
        const SizedBox(height: 16),
        const Text(
          'Контрольные задания',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Набор: ${state.suiteName} · ${state.device}',
          style: const TextStyle(color: Colors.white60),
        ),
        const SizedBox(height: 10),
        const Text(
          'Каждая проверка выполняется независимо. Открой результат, '
          'чтобы увидеть запрос и ожидаемый ответ. Короткие задания '
          'проверяют ответы модели; для скорости используй замер выше.',
          style: TextStyle(fontSize: 12, color: Colors.white60),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: state.isReady && !state.busy ? state.runSmoke : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Проверить ответы'),
            ),
            _ExportButton(
              state: state,
              performance: false,
              enabled: state.evalStartedAt != null && !state.busy,
              label: 'JSON проверок',
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (state.evalStatus == 'cancelled')
          const Text(
            'Проверки остановлены: результаты неполные.',
            style: TextStyle(color: Colors.orangeAccent),
          )
        else if (state.evalStatus == 'error')
          const Text(
            'Проверки прерваны из-за ошибки. Подробности сохранены в JSON.',
            style: TextStyle(color: Colors.orangeAccent),
          ),
        if (state.evals.isEmpty)
          const Text(
            'Результатов проверок пока нет',
            style: TextStyle(color: Colors.white60),
          ),
        for (final result in state.evals) _EvaluationCard(result),
      ],
    );
  }
}

class _ExportButton extends StatelessWidget {
  const _ExportButton({
    required this.state,
    required this.performance,
    required this.enabled,
    required this.label,
  });
  final LabState state;
  final bool performance;
  final bool enabled;
  final String label;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: enabled
          ? () async {
              final box = context.findRenderObject()! as RenderBox;
              await state.exportResults(
                performance: performance,
                sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
              );
            }
          : null,
      icon: const Icon(Icons.ios_share),
      label: Text(label),
    );
  }
}

String _metric(Object? value) =>
    value is num && value.isFinite ? value.toStringAsFixed(1) : '—';

class _BenchmarkSummary extends StatelessWidget {
  const _BenchmarkSummary({required this.source, required this.values});
  final String source;
  final Map<String, Object?> values;

  Map<String, Object?> _stats(String metric) =>
      values[metric] as Map<String, Object?>;

  Widget _metricLine(String label, String metric, String unit) {
    final stats = _stats(metric);
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Text(
        '$label: медиана ${_metric(stats['median'])} $unit · '
        'p90 ${_metric(stats['p90'])} $unit · n=${stats['count']}',
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final speed = _stats('decode_tokens_per_s');
    final hasSpeed = (speed['count'] as int) > 0;
    final estimated = source == 'sse-wallclock';
    return Card(
      key: Key('benchmark-summary-$source'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(source, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 7),
            Text(
              'Завершено: ${values['completed_count']} · '
              'коротких: ${values['short_output_count']} · '
              'без числа токенов: ${values['unknown_decode_tokens_count']} · '
              'отменено: ${values['cancelled_count']} · '
              'ошибок: ${values['error_count']}',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
            if (hasSpeed)
              KeyedSubtree(
                key: Key('aggregate-decode-$source'),
                child: _metricLine(
                  estimated ? 'Скорость по всему времени запроса' : 'Генерация',
                  'decode_tokens_per_s',
                  'ток/с',
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Скорость не рассчитана: нет подходящих длинных ответов с метриками.',
                  style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
                ),
              ),
            if (estimated)
              const Padding(
                padding: EdgeInsets.only(top: 7),
                child: Text(
                  'Оценка по SSE, включая обработку запроса; это не нативная скорость декодирования.',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
            _metricLine('Первый текст в приложении', 'ttft_ms', 'мс'),
            _metricLine('Полное время ответа', 'total_ms', 'мс'),
          ],
        ),
      ),
    );
  }
}

class _BenchmarkSampleCard extends StatelessWidget {
  const _BenchmarkSampleCard(this.sample);
  final BenchmarkSample sample;

  @override
  Widget build(BuildContext context) {
    final metrics = sample.metrics;
    final status = switch (sample.status) {
      'completed' => 'завершён',
      'cancelled' => 'отменён',
      _ => 'ошибка',
    };
    return Card(
      child: ExpansionTile(
        title: Text(
          '${sample.phase == 'warmup' ? 'Прогрев' : 'Замер'} ${sample.index} · $status',
        ),
        subtitle: Text(
          'Токенов: ${metrics?.decodeTokens ?? '—'} · '
          'время: ${metrics?.totalMs ?? '—'} мс',
          style: const TextStyle(fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sample.error != null)
            SelectableText(
              sample.error!,
              style: const TextStyle(color: Colors.orangeAccent),
            ),
          Text('Метод: ${metrics?.source ?? 'нет метрик'}'),
          Text('Первый текст: ${metrics?.ttftMs ?? '—'} мс'),
          Text(
            '${metrics?.source == 'sse-wallclock' ? 'SSE по всему времени запроса' : 'Генерация'}: '
            '${_metric(metrics?.decodeTps)} ток/с',
          ),
          const SizedBox(height: 8),
          SelectableText('Запрос: ${sample.prompt}'),
          const SizedBox(height: 8),
          SelectableText(
            'Ответ: ${sample.response.isEmpty ? '—' : sample.response}',
          ),
        ],
      ),
    );
  }
}

class _EvaluationCard extends StatelessWidget {
  const _EvaluationCard(this.result);
  final EvalResult result;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        key: Key('eval-${result.caseId}'),
        leading: Icon(
          result.passed ? Icons.check_circle : Icons.cancel,
          color: result.passed ? const Color(0xFF33D6A6) : Colors.orangeAccent,
        ),
        title: Text(result.caseId),
        subtitle: Text(result.passed ? 'Пройдена' : 'Не пройдена'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText('Запрос: ${result.test.prompt}'),
          const SizedBox(height: 8),
          Text('Условие: ${result.test.kind}'),
          Text('Ожидается: ${result.test.expected ?? 'JSON-объект'}'),
          const SizedBox(height: 8),
          SelectableText('Ответ: ${result.response}'),
          const SizedBox(height: 8),
          Text(
            'Первый текст в приложении: ${result.metrics.ttftMs ?? '—'} мс · '
            'полное время: ${result.metrics.totalMs} мс',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          Text(
            'Метод: ${result.metrics.source}',
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
        ],
      ),
    );
  }
}
