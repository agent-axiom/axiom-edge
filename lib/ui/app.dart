import 'dart:io';
import 'package:flutter/material.dart';

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
              'TTFT ${s.lastMetrics!.ttftMs ?? '—'} мс  •  decode ${s.lastMetrics!.decodeTps?.toStringAsFixed(1) ?? '—'} ток/с  •  ${s.lastMetrics!.totalMs} мс',
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

  String _metric(double? v) => v == null ? '—' : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
          'Каждая проверка выполняется независимо. Условия и ограничения генерации одинаковые; скорость зависит от прогрева, кэша и состояния устройства.',
          style: TextStyle(fontSize: 12, color: Colors.white60),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            FilledButton.icon(
              onPressed: state.isReady && !state.busy ? state.runSmoke : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Запустить'),
            ),
            const SizedBox(width: 8),
            Builder(
              builder: (buttonContext) => OutlinedButton.icon(
                onPressed: state.evals.isNotEmpty && !state.busy
                    ? () async {
                        final box =
                            buttonContext.findRenderObject()! as RenderBox;
                        await state.exportResults(
                          sharePositionOrigin:
                              box.localToGlobal(Offset.zero) & box.size,
                        );
                      }
                    : null,
                icon: const Icon(Icons.ios_share),
                label: const Text('JSON'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (state.evals.isEmpty)
          const Text(
            'Результатов пока нет',
            style: TextStyle(color: Colors.white60),
          ),
        for (final e in state.evals)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        e.passed ? Icons.check_circle : Icons.cancel,
                        color: e.passed
                            ? const Color(0xFF33D6A6)
                            : Colors.orangeAccent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          e.caseId,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(
                    'TTFT: ${e.metrics.ttftMs ?? '—'} мс  ·  Decode: ${_metric(e.metrics.decodeTps)} ток/с  ·  Total: ${e.metrics.totalMs} мс',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Метод: ${e.metrics.source}',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(e.response, maxLines: 8),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
