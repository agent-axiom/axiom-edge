import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../chat/chat_models.dart';
import '../chat/chat_state.dart';

const _green = Color(0xFF33D6A6);

/// The cloud conversation body. Its owner controls the ChatState lifecycle.
class CloudChatPage extends StatefulWidget {
  const CloudChatPage(this.state, {super.key});
  final ChatState state;

  @override
  State<CloudChatPage> createState() => _CloudChatPageState();
}

class _CloudChatPageState extends State<CloudChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  String? _threadId;
  String _observedDraft = '';
  String? _pendingText;
  int _userCountBeforeSend = 0;
  bool _nearBottom = true;
  bool _showLatest = false;

  @override
  void initState() {
    super.initState();
    _threadId = widget.state.currentThread?.id;
    _input.text = widget.state.draft;
    _observedDraft = widget.state.draft;
    widget.state.addListener(_stateChanged);
    _scroll.addListener(_scrolled);
  }

  @override
  void didUpdateWidget(covariant CloudChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_stateChanged);
      widget.state.addListener(_stateChanged);
      _threadId = widget.state.currentThread?.id;
      _input.text = widget.state.draft;
    }
  }

  void _stateChanged() {
    if (!mounted) return;
    final state = widget.state;
    final thread = state.currentThread;
    if (state.draft != _observedDraft) {
      final previous = _observedDraft;
      _observedDraft = state.draft;
      if (_input.text == previous) _input.text = state.draft;
    }
    if (_threadId != thread?.id) {
      _threadId = thread?.id;
      _input.text = state.draft;
      _nearBottom = true;
      _showLatest = false;
    }
    if (_pendingText != null &&
        (thread?.messages.where((m) => m.role == 'user').length ?? 0) >
            _userCountBeforeSend &&
        thread!.messages.where((m) => m.role == 'user').last.text ==
            _pendingText) {
      // The state publishes the user message only after its initial save.
      if (_input.text.trim() == _pendingText) _input.clear();
      _pendingText = null;
    }
    if (_nearBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients && _nearBottom) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _scrolled() {
    if (!_scroll.hasClients) return;
    _nearBottom = _scroll.position.extentAfter < 100;
    final show = !_nearBottom;
    if (show != _showLatest && mounted) setState(() => _showLatest = show);
  }

  Future<void> _send() async {
    final state = widget.state;
    final text = _input.text.trim();
    if (text.isEmpty || state.generating || !state.initialized) return;
    _pendingText = text;
    _userCountBeforeSend =
        state.currentThread?.messages.where((m) => m.role == 'user').length ??
        0;
    _nearBottom = true;
    final accepted = await state.send(text);
    if (!mounted) return;
    if (accepted && _pendingText == text && _input.text.trim() == text) {
      _input.clear();
    }
    _pendingText = null;
  }

  void _fillPrompt(String prompt) {
    _input.text = prompt;
    _input.selection = TextSelection.collapsed(offset: prompt.length);
    widget.state.setDraft(prompt);
    _focus.requestFocus();
  }

  Future<void> _chooseModel() async {
    final selection = await showModalBottomSheet<_ModelSelection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ModelSheet(widget.state),
    );
    if (selection == null || !mounted) return;
    final state = widget.state;
    final current = state.currentThread;
    if (current != null &&
        current.messages.isNotEmpty &&
        (current.provider != selection.provider ||
            current.model != selection.model)) {
      final confirmed = await _confirm(
        context,
        title: 'Новый чат с ${selection.provider.label}?',
        body:
            'Текущая переписка останется в истории. Новый чат будет пустым. '
            'Его сообщения будут отправляться ${selection.provider.label}.',
        action: 'Создать чат',
      );
      if (confirmed) {
        await state.newChat(
          provider: selection.provider,
          model: selection.model,
        );
      }
    } else {
      await state.selectModel(selection.provider, selection.model);
    }
  }

  void _openSettings() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => ProviderSettingsPage(widget.state)),
    );
  }

  Future<void> _systemPrompt() async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _TextEditDialog(
        title: 'Инструкция для чата',
        initial: widget.state.systemPrompt,
        hint: 'Например: отвечай кратко и по-русски',
        helper: 'Необязательно. Отправляется провайдеру вместе с чатом.',
        multiline: true,
      ),
    );
    if (value != null) await widget.state.updateSystemPrompt(value);
  }

  Future<void> _history() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _HistorySheet(widget.state),
  );

  Future<void> _export(bool share) async {
    final thread = widget.state.currentThread;
    if (thread == null) return;
    final text = _asMarkdown(thread);
    if (share) {
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          text: text,
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } else if (mounted) {
      await _copy(context, text, 'Чат скопирован');
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_stateChanged);
    _scroll.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) {
      final state = widget.state;
      final messages = state.currentThread?.messages ?? const <ChatMessage>[];
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'История чатов',
                  onPressed: _history,
                  icon: const Icon(Icons.menu),
                ),
                Expanded(
                  child: TextButton(
                    onPressed: state.generating ? null : _chooseModel,
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          state.selectedProvider.label,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          state.selectedModel.isEmpty
                              ? 'Выбрать модель'
                              : state.selectedModel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Новый чат',
                  onPressed: state.generating ? null : () => state.newChat(),
                  icon: const Icon(Icons.edit_square),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Настройки чата',
                  onSelected: (value) {
                    switch (value) {
                      case 'providers':
                        _openSettings();
                      case 'system':
                        unawaited(_systemPrompt());
                      case 'copy':
                        unawaited(_export(false));
                      case 'share':
                        unawaited(_export(true));
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'providers',
                      child: Text('Провайдеры и ключи'),
                    ),
                    PopupMenuItem(
                      value: 'system',
                      enabled: !state.generating,
                      child: const Text('Инструкция для чата'),
                    ),
                    PopupMenuItem(
                      value: 'copy',
                      enabled: messages.isNotEmpty,
                      child: const Text('Скопировать чат'),
                    ),
                    PopupMenuItem(
                      value: 'share',
                      enabled: messages.isNotEmpty,
                      child: const Text('Поделиться чатом'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (!state.initialized) const LinearProgressIndicator(),
          if (state.storageError != null)
            _Notice(
              text: 'Хранилище: ${state.storageError}',
              action: 'Повторить',
              onAction: () => state.flush(),
            ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: messages.isEmpty
                      ? _Welcome(
                          ready: state.initialized,
                          hasKey: state.hasKey(state.selectedProvider),
                          onSettings: _openSettings,
                          onPrompt: _fillPrompt,
                        )
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                          itemCount: messages.length,
                          itemBuilder: (context, index) => Align(
                            alignment: Alignment.topCenter,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 840),
                              child: _MessageView(
                                message: messages[index],
                                last: index == messages.length - 1,
                                generating: state.generating,
                                onRetry: state.retry,
                                onRegenerate: state.regenerate,
                              ),
                            ),
                          ),
                        ),
                ),
                if (_showLatest && messages.isNotEmpty)
                  Positioned(
                    right: 16,
                    bottom: 12,
                    child: FilledButton.tonalIcon(
                      onPressed: () {
                        _nearBottom = true;
                        _scroll.animateTo(
                          _scroll.position.maxScrollExtent,
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                        );
                      },
                      icon: const Icon(Icons.arrow_downward, size: 18),
                      label: const Text('К последнему'),
                    ),
                  ),
              ],
            ),
          ),
          if (state.error != null) _Notice(text: state.error!),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFF18232C),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Focus(
                            onKeyEvent: (_, event) {
                              if (event is! KeyDownEvent ||
                                  event.logicalKey !=
                                      LogicalKeyboardKey.enter ||
                                  (_input.value.composing.isValid &&
                                      !_input.value.composing.isCollapsed)) {
                                return KeyEventResult.ignored;
                              }
                              if (HardwareKeyboard.instance.isShiftPressed) {
                                final selected = _input.selection;
                                final start = selected.isValid
                                    ? selected.start
                                    : _input.text.length;
                                final end = selected.isValid
                                    ? selected.end
                                    : start;
                                _input.value = TextEditingValue(
                                  text: _input.text.replaceRange(
                                    start,
                                    end,
                                    '\n',
                                  ),
                                  selection: TextSelection.collapsed(
                                    offset: start + 1,
                                  ),
                                );
                                state.setDraft(_input.text);
                              } else {
                                unawaited(_send());
                              }
                              return KeyEventResult.handled;
                            },
                            child: TextField(
                              key: const Key('cloud-composer'),
                              controller: _input,
                              focusNode: _focus,
                              enabled: state.initialized,
                              onChanged: state.setDraft,
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.newline,
                              minLines: 1,
                              maxLines: 5,
                              decoration: const InputDecoration(
                                hintText: 'Спросите что-нибудь',
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: state.generating
                              ? IconButton.filled(
                                  tooltip: 'Остановить ответ',
                                  onPressed: state.stop,
                                  icon: const Icon(Icons.stop_rounded),
                                )
                              : IconButton.filled(
                                  tooltip: 'Отправить сообщение',
                                  onPressed: state.initialized ? _send : null,
                                  icon: const Icon(Icons.arrow_upward),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _Welcome extends StatelessWidget {
  const _Welcome({
    required this.ready,
    required this.hasKey,
    required this.onSettings,
    required this.onPrompt,
  });
  final bool ready;
  final bool hasKey;
  final VoidCallback onSettings;
  final ValueChanged<String> onPrompt;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.auto_awesome, color: _green, size: 36),
            const SizedBox(height: 18),
            const Text(
              'С чего начнём?',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            const Text(
              'Ваши модели, ваши ключи. Один спокойный чат.',
              style: TextStyle(color: Colors.white60),
            ),
            if (ready && !hasKey) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: onSettings,
                icon: const Icon(Icons.key),
                label: const Text('Добавить API-ключ'),
              ),
            ],
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final prompt in const [
                  'Объясни сложную тему простыми словами',
                  'Помоги проверить мой Python-код',
                  'Составим план проекта',
                  'Помоги отредактировать текст',
                ])
                  ActionChip(
                    label: Text(prompt),
                    onPressed: ready ? () => onPrompt(prompt) : null,
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.action, this.onAction});
  final String text;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: const Color(0xFF302817),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          style: const TextStyle(color: Color(0xFFFFDDA4), fontSize: 12),
        ),
        if (action != null)
          TextButton(onPressed: onAction, child: Text(action!)),
      ],
    ),
  );
}

class _MessageView extends StatelessWidget {
  const _MessageView({
    required this.message,
    required this.last,
    required this.generating,
    required this.onRetry,
    required this.onRegenerate,
  });
  final ChatMessage message;
  final bool last;
  final bool generating;
  final Future<void> Function() onRetry;
  final Future<void> Function() onRegenerate;

  @override
  Widget build(BuildContext context) {
    final user = message.role == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: user
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (user)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF134F43),
                borderRadius: BorderRadius.circular(18),
              ),
              child: SelectableText(message.text),
            )
          else ...[
            Text(
              message.model.isEmpty ? 'Axiom' : message.model,
              style: const TextStyle(fontSize: 12, color: _green),
            ),
            const SizedBox(height: 8),
            if (message.reasoning.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text(
                  'Рассуждение',
                  style: TextStyle(fontSize: 12, color: Colors.white60),
                ),
                children: [SelectableText(message.reasoning)],
              ),
            if (message.text.isNotEmpty)
              _RichMessage(message.text)
            else if (message.status == ChatMessageStatus.streaming)
              const Text('Печатает…', style: TextStyle(color: Colors.white60)),
            if (message.status == ChatMessageStatus.stopped)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Остановлено · неполный ответ',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
            if (message.status == ChatMessageStatus.failed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  message.error ?? 'Не удалось получить ответ',
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
          ],
          Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (message.text.isNotEmpty)
                IconButton(
                  tooltip: 'Скопировать сообщение',
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      _copy(context, message.text, 'Сообщение скопировано'),
                  icon: const Icon(Icons.copy_outlined, size: 16),
                ),
              if (!user && last && !generating)
                TextButton.icon(
                  onPressed: message.status == ChatMessageStatus.failed
                      ? onRetry
                      : onRegenerate,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(
                    message.status == ChatMessageStatus.failed
                        ? 'Повторить'
                        : 'Другой ответ',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RichMessage extends StatelessWidget {
  const _RichMessage(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    final plain = StringBuffer();
    void flush() {
      if (plain.isEmpty) return;
      children.add(
        MarkdownBody(
          data: plain.toString(),
          selectable: true,
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
            p: const TextStyle(height: 1.5, fontSize: 15),
            tableColumnWidth: const FlexColumnWidth(),
          ),
          // Model output must never make tracking requests or read local files.
          imageBuilder: (uri, title, alt) =>
              Text('Изображение: ${alt ?? uri.toString()}'),
          onTapLink: (_, href, _) {
            if (href != null) {
              unawaited(_copy(context, href, 'Ссылка скопирована'));
            }
          },
        ),
      );
      plain.clear();
    }

    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final opening = RegExp(
        r'^\s{0,3}(`{3,}|~{3,})(.*)$',
      ).firstMatch(lines[i]);
      if (opening == null) {
        plain.writeln(lines[i]);
        continue;
      }
      flush();
      final fence = opening.group(1)!;
      final language = opening.group(2)!.trim();
      final closing = RegExp(
        '^\\s{0,3}${RegExp.escape(fence[0])}{${fence.length},}\\s*\$',
      );
      final code = <String>[];
      while (++i < lines.length && !closing.hasMatch(lines[i])) {
        code.add(lines[i]);
      }
      children.add(_CodeBlock(code.join('\n'), language: language));
    }
    flush();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final child in children)
          Padding(padding: const EdgeInsets.only(bottom: 10), child: child),
      ],
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock(this.code, {required this.language});
  final String code;
  final String language;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: const Color(0xFF101820),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  language.isEmpty ? 'Код' : language,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ),
              IconButton(
                tooltip: 'Скопировать код',
                onPressed: () => _copy(context, code, 'Код скопирован'),
                icon: const Icon(Icons.copy_outlined, size: 16),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: SelectableText(
            code,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ),
      ],
    ),
  );
}

Future<void> _copy(BuildContext context, String value, String notice) async {
  await Clipboard.setData(ClipboardData(text: value));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(notice)));
  }
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

String _asMarkdown(ChatThread thread) => [
  '# ${thread.title}',
  '${thread.provider.label} · ${thread.model}',
  if (thread.systemPrompt.isNotEmpty) '## Инструкция\n\n${thread.systemPrompt}',
  for (final message in thread.messages)
    '## ${message.role == 'user' ? 'Вы' : 'Ассистент'}\n\n${message.text}'
        '${message.status == ChatMessageStatus.stopped ? '\n\n_Ответ остановлен._' : ''}'
        '${message.status == ChatMessageStatus.failed ? '\n\n_Ошибка: ${message.error ?? 'нет ответа'}_' : ''}',
].join('\n\n');

class ProviderSettingsPage extends StatefulWidget {
  const ProviderSettingsPage(this.state, {super.key});
  final ChatState state;
  @override
  State<ProviderSettingsPage> createState() => _ProviderSettingsPageState();
}

class _ProviderSettingsPageState extends State<ProviderSettingsPage> {
  final _key = TextEditingController();
  late CloudProvider _provider = widget.state.selectedProvider;
  bool _working = false;
  final _failedRemovals = <CloudProvider>{};
  String? _notice;

  Future<void> _run(Future<void> Function() action) async {
    if (_working) return;
    setState(() {
      _working = true;
      _notice = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _notice = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Провайдеры и ключи')),
    body: ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Подключите свой API-ключ',
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          const Text(
            'Ключ хранится в защищённом хранилище устройства. '
            'Сообщения отправляются выбранному провайдеру. '
            'Запросы API оплачиваются отдельно от подписки ChatGPT или Z.AI.',
            style: TextStyle(color: Colors.white70, height: 1.5),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final provider in CloudProvider.values)
                ChoiceChip(
                  label: Text(provider.label),
                  selected: provider == _provider,
                  onSelected: _working
                      ? null
                      : (_) => setState(() {
                          _provider = provider;
                          _key.clear();
                          _notice = null;
                        }),
                ),
            ],
          ),
          const SizedBox(height: 16),
          SelectableText(
            _provider.baseUri.toString(),
            style: const TextStyle(color: _green, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Text(
            _failedRemovals.contains(_provider)
                ? 'Удаление ключа нужно повторить'
                : widget.state.hasKey(_provider)
                ? 'Ключ сохранён'
                : 'Ключ не подключён',
            style: TextStyle(
              color: widget.state.hasKey(_provider) ? _green : Colors.white60,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('provider-api-key'),
            controller: _key,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            keyboardType: TextInputType.visiblePassword,
            enabled: !_working,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Новый API-ключ',
              hintText: 'Вставьте ключ провайдера',
              border: OutlineInputBorder(),
              helperText: 'Сохранённый ключ здесь не показывается.',
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _working || _key.text.trim().isEmpty
                    ? null
                    : () => _run(() async {
                        await widget.state.saveKey(_provider, _key.text.trim());
                        if (!mounted) return;
                        if (widget.state.error == null) {
                          _key.clear();
                          _failedRemovals.remove(_provider);
                          if (mounted) {
                            setState(
                              () => _notice = 'Ключ сохранён на устройстве.',
                            );
                          }
                        }
                      }),
                icon: const Icon(Icons.lock_outline),
                label: const Text('Сохранить ключ'),
              ),
              OutlinedButton(
                onPressed: _working || !widget.state.hasKey(_provider)
                    ? null
                    : () => _run(() async {
                        final ok = await widget.state.testConnection(_provider);
                        if (mounted) {
                          setState(
                            () => _notice = ok
                                ? 'Список моделей получен. Доступ к конкретной модели проверяется при отправке.'
                                : widget.state.catalogErrorFor(_provider) ??
                                      widget.state.error ??
                                      'Не удалось проверить подключение.',
                          );
                        }
                      }),
                child: const Text('Проверить подключение'),
              ),
              TextButton.icon(
                key: const Key('remove-provider-key'),
                onPressed: _working
                    ? null
                    : () async {
                        final confirmed = await _confirm(
                          context,
                          title: 'Удалить ключ ${_provider.label}?',
                          body:
                              'Чаты останутся на устройстве. Для новых запросов понадобится API-ключ.',
                          action: 'Удалить ключ',
                        );
                        if (confirmed) {
                          await _run(() async {
                            await widget.state.removeKey(_provider);
                            if (widget.state.error != null) {
                              _failedRemovals.add(_provider);
                            } else {
                              _failedRemovals.remove(_provider);
                            }
                            if (mounted) {
                              setState(
                                () => _notice =
                                    widget.state.error ?? 'Ключ удалён.',
                              );
                            }
                          });
                        }
                      },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Удалить ключ'),
              ),
            ],
          ),
          if (_working)
            const Padding(
              padding: EdgeInsets.only(top: 18),
              child: LinearProgressIndicator(),
            ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_notice!),
            ),
          if (widget.state.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                widget.state.error!,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
          if (widget.state.storageError != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                widget.state.storageError!,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
        ],
      ),
    ),
  );
}

class _ModelSelection {
  const _ModelSelection(this.provider, this.model);
  final CloudProvider provider;
  final String model;
}

class _ModelSheet extends StatefulWidget {
  const _ModelSheet(this.state);
  final ChatState state;
  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  final _search = TextEditingController();
  final _manual = TextEditingController();
  late CloudProvider _provider = widget.state.selectedProvider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.state.refreshModels(_provider));
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _manual.dispose();
    super.dispose();
  }

  void _select(String id) {
    if (id.trim().isNotEmpty) {
      Navigator.pop(context, _ModelSelection(_provider, id.trim()));
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .85,
      child: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final catalog = widget.state.catalogs[_provider];
          final ids = (catalog?.modelIds ?? const <String>[])
              .where(
                (id) => id.toLowerCase().contains(_search.text.toLowerCase()),
              )
              .toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Выбрать модель',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Обновить список',
                    onPressed: widget.state.isModelsLoading(_provider)
                        ? null
                        : () => widget.state.refreshModels(_provider),
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: 'Закрыть выбор модели',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final provider in CloudProvider.values)
                    ChoiceChip(
                      label: Text(provider.label),
                      selected: _provider == provider,
                      onSelected: (_) {
                        setState(() {
                          _provider = provider;
                          _search.clear();
                          _manual.clear();
                        });
                        unawaited(widget.state.refreshModels(provider));
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('model-search'),
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Поиск по ID модели',
                ),
              ),
              if (widget.state.isModelsLoading(_provider))
                const LinearProgressIndicator(),
              if (catalog?.fetchedAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${catalog!.isStale ? 'Сохранённый список устарел' : 'Список получен'}: ${_date(catalog.fetchedAt!)}',
                    style: const TextStyle(color: Colors.white60, fontSize: 11),
                  ),
                ),
              if (widget.state.catalogErrorFor(_provider) != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${widget.state.catalogErrorFor(_provider)}${catalog?.modelIds.isNotEmpty == true ? '\nПоказан сохранённый список; доступность могла измениться.' : ''}',
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 12,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('manual-model-id'),
                controller: _manual,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() {}),
                onSubmitted: _select,
                decoration: const InputDecoration(
                  labelText: 'ID модели вручную',
                  helperText: 'Провайдер проверит доступ при запросе.',
                  helperMaxLines: 2,
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _manual.text.trim().isEmpty
                      ? null
                      : () => _select(_manual.text),
                  child: const Text('Использовать ID'),
                ),
              ),
              const Divider(),
              if (ids.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    widget.state.isModelsLoading(_provider)
                        ? 'Получаем список…'
                        : _search.text.isNotEmpty
                        ? 'Совпадений нет'
                        : 'Список моделей пока не получен. Обновите его или введите ID вручную.',
                    style: const TextStyle(color: Colors.white60),
                  ),
                ),
              for (final id in ids)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(id, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing:
                      widget.state.selectedProvider == _provider &&
                          widget.state.selectedModel == id
                      ? const Icon(Icons.check, color: _green)
                      : null,
                  onTap: () => _select(id),
                ),
            ],
          );
        },
      ),
    ),
  );
}

class _HistorySheet extends StatefulWidget {
  const _HistorySheet(this.state);
  final ChatState state;
  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  final _search = TextEditingController();
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _rename(ChatThread thread) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) =>
          _TextEditDialog(title: 'Название чата', initial: thread.title),
    );
    if (title != null && title.trim().isNotEmpty) {
      await widget.state.renameThread(thread.id, title.trim());
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .85,
      child: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final query = _search.text.trim().toLowerCase();
          final threads = widget.state.threads
              .where(
                (thread) =>
                    thread.title.toLowerCase().contains(query) ||
                    thread.messages.any(
                      (m) => m.text.toLowerCase().contains(query),
                    ),
              )
              .toList();
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'История чатов',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Закрыть историю',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                TextField(
                  key: const Key('history-search'),
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Название или текст сообщения',
                  ),
                ),
                const SizedBox(height: 12),
                if (widget.state.generating)
                  const Text(
                    'Остановите ответ, чтобы открыть другой чат.',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                Expanded(
                  child: threads.isEmpty
                      ? Center(
                          child: Text(
                            query.isEmpty
                                ? 'Сохранённых чатов пока нет'
                                : 'Ничего не найдено',
                            style: const TextStyle(color: Colors.white60),
                          ),
                        )
                      : ListView.builder(
                          itemCount: threads.length,
                          itemBuilder: (context, i) {
                            final thread = threads[i];
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              selected:
                                  thread.id == widget.state.currentThread?.id,
                              title: Text(
                                thread.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${thread.provider.label} · ${thread.model}\n${_date(thread.updatedAt)}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: widget.state.generating
                                  ? null
                                  : () async {
                                      await widget.state.openThread(thread.id);
                                      if (context.mounted) {
                                        Navigator.pop(context);
                                      }
                                    },
                              trailing: PopupMenuButton<String>(
                                tooltip: 'Действия с чатом',
                                enabled: !widget.state.generating,
                                onSelected: (action) async {
                                  if (action == 'rename') {
                                    await _rename(thread);
                                  } else {
                                    final confirmed = await _confirm(
                                      context,
                                      title: 'Удалить чат?',
                                      body:
                                          '«${thread.title}» будет удалён с этого устройства.',
                                      action: 'Удалить',
                                    );
                                    if (confirmed) {
                                      await widget.state.deleteThread(
                                        thread.id,
                                      );
                                    }
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: Text('Переименовать'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Удалить'),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

String _date(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} ${two(local.hour)}:${two(local.minute)}';
}

class _TextEditDialog extends StatefulWidget {
  const _TextEditDialog({
    required this.title,
    required this.initial,
    this.hint,
    this.helper,
    this.multiline = false,
  });
  final String title;
  final String initial;
  final String? hint;
  final String? helper;
  final bool multiline;
  @override
  State<_TextEditDialog> createState() => _TextEditDialogState();
}

class _TextEditDialogState extends State<_TextEditDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    scrollable: true,
    content: SizedBox(
      width: 480,
      child: TextField(
        controller: _controller,
        minLines: widget.multiline ? 3 : 1,
        maxLines: widget.multiline ? 8 : 2,
        maxLength: widget.multiline ? null : 120,
        decoration: InputDecoration(
          hintText: widget.hint,
          helperText: widget.helper,
          helperMaxLines: 3,
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Сохранить'),
      ),
    ],
  );
}
