import 'dart:async';

import 'package:axiom_edge/chat/chat_models.dart';
import 'package:axiom_edge/chat/chat_state.dart';
import 'package:axiom_edge/chat/chat_store.dart';
import 'package:axiom_edge/core/models.dart';
import 'package:axiom_edge/ui/cloud_chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryHistory implements ChatPersistence {
  MemoryHistory([ChatArchive? value]) : archive = value ?? ChatArchive.empty();
  ChatArchive archive;
  bool failWrites = false;
  @override
  Future<ChatArchive> load() async => archive;
  @override
  Future<void> save(ChatArchive value) async {
    if (failWrites) throw StateError('disk full');
    archive = value;
  }
}

class MemoryKeys implements ChatKeyVault {
  final values = <CloudProvider, String>{};
  bool failDelete = false;
  @override
  Future<String?> read(CloudProvider provider) async => values[provider];
  @override
  Future<void> write(CloudProvider provider, String key) async =>
      values[provider] = key;
  @override
  Future<void> delete(CloudProvider provider) async {
    if (failDelete) throw StateError('vault unavailable');
    values.remove(provider);
  }
}

class FakeCloud implements CloudGateway {
  final models = <CloudProvider, List<String>>{
    CloudProvider.openai: ['live-openai-model'],
    CloudProvider.zai: ['live-zai-model'],
  };
  final modelRequests = <CloudProvider>[];
  final requests = <List<ChatTurn>>[];
  StreamController<CloudChunk>? controller;
  int cancels = 0;
  @override
  Future<List<String>> listModels(CloudProvider provider, String apiKey) async {
    modelRequests.add(provider);
    return models[provider]!;
  }

  @override
  Stream<CloudChunk> stream({
    required CloudProvider provider,
    required String apiKey,
    required String model,
    required List<ChatTurn> messages,
    String systemPrompt = '',
  }) {
    requests.add(messages);
    controller = StreamController<CloudChunk>();
    return controller!.stream;
  }

  @override
  void cancel() {
    cancels++;
  }

  @override
  void close() {
    unawaited(controller?.close());
  }
}

Future<ChatState> chatState({
  MemoryHistory? history,
  MemoryKeys? keys,
  FakeCloud? cloud,
}) async {
  final state = ChatState(
    store: history ?? MemoryHistory(),
    keyVault: keys ?? MemoryKeys(),
    gateway: cloud ?? FakeCloud(),
    streamSaveDebounce: const Duration(milliseconds: 20),
  );
  await state.init();
  addTearDown(state.dispose);
  return state;
}

Future<void> mount(WidgetTester tester, ChatState state, {Widget? page}) async {
  await tester.binding.setSurfaceSize(const Size(320, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF33D6A6),
        scaffoldBackgroundColor: const Color(0xFF0B1015),
        useMaterial3: true,
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(1.5)),
        child: child!,
      ),
      home: page ?? Scaffold(body: CloudChatPage(state)),
    ),
  );
  await tester.pumpAndSettle();
}

Finder sheetScroll() => find
    .descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable))
    .first;

ChatThread thread(
  String id,
  String title,
  String content, {
  CloudProvider provider = CloudProvider.openai,
}) {
  final date = DateTime.utc(2026, 11, 17);
  return ChatThread(
    id: id,
    title: title,
    provider: provider,
    model: 'saved-model',
    createdAt: date,
    updatedAt: date,
    messages: [
      ChatMessage(
        id: '$id-u',
        role: 'user',
        text: content,
        provider: provider,
        model: 'saved-model',
        createdAt: date,
      ),
    ],
  );
}

void main() {
  testWidgets(
    'empty chat fits narrow enlarged layout and prompts become drafts',
    (tester) async {
      final state = await chatState();
      await mount(tester, state);
      expect(find.text('С чего начнём?'), findsOneWidget);
      expect(find.text('Добавить API-ключ'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final prompt = find.text('Помоги проверить мой Python-код');
      await tester.ensureVisible(prompt);
      await tester.tap(prompt);
      await tester.pump();
      expect(state.draft, 'Помоги проверить мой Python-код');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('cloud-composer')))
            .controller!
            .text,
        state.draft,
      );
      expect(tester.takeException(), isNull);
      await state.flush();
    },
  );

  testWidgets(
    'missing key and failed initial save retain unsent composer text',
    (tester) async {
      final history = MemoryHistory(
        ChatArchive(selectedModels: {CloudProvider.openai: 'chosen-model'}),
      );
      final keys = MemoryKeys();
      final cloud = FakeCloud();
      final state = await chatState(history: history, keys: keys, cloud: cloud);
      await mount(tester, state);
      final composer = find.byKey(const Key('cloud-composer'));
      await tester.enterText(composer, 'Keep my question');
      await tester.tap(find.byTooltip('Отправить сообщение'));
      await tester.pumpAndSettle();
      expect(find.text('Добавь API-ключ OpenAI.'), findsOneWidget);
      expect(
        tester.widget<TextField>(composer).controller!.text,
        'Keep my question',
      );
      expect(cloud.requests, isEmpty);
      await state.saveKey(CloudProvider.openai, 'key-for-test');
      history.failWrites = true;
      await tester.tap(find.byTooltip('Отправить сообщение'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(composer).controller!.text,
        'Keep my question',
      );
      expect(state.currentThread, isNull);
      expect(cloud.requests, isEmpty);
      expect(
        find.textContaining('Не удалось сохранить переписку'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings never reveal saved keys and failed deletion can be retried',
    (tester) async {
      final keys = MemoryKeys()
        ..values[CloudProvider.openai] = 'saved-secret-do-not-display';
      final state = await chatState(keys: keys);
      await mount(tester, state, page: ProviderSettingsPage(state));
      final field = find.byKey(const Key('provider-api-key'));
      await tester.scrollUntilVisible(
        field,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      final input = tester.widget<TextField>(field);
      expect(input.obscureText, isTrue);
      expect(input.controller!.text, isEmpty);
      expect(find.text('saved-secret-do-not-display'), findsNothing);
      await tester.enterText(field, 'replacement-secret');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Сохранить ключ'));
      await tester.tap(find.text('Сохранить ключ'));
      await tester.pumpAndSettle();
      expect(keys.values[CloudProvider.openai], 'replacement-secret');
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      await tester.ensureVisible(find.text('Проверить подключение'));
      await tester.tap(find.text('Проверить подключение'));
      await tester.pumpAndSettle();
      expect(state.catalogs[CloudProvider.openai]!.modelIds, [
        'live-openai-model',
      ]);
      keys.failDelete = true;
      await tester.ensureVisible(find.text('Удалить ключ'));
      await tester.tap(find.text('Удалить ключ'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Удалить ключ'));
      await tester.pumpAndSettle();
      expect(keys.values[CloudProvider.openai], 'replacement-secret');
      expect(find.text('Ключ удалён.'), findsNothing);
      // Reopening settings discards local page state: retry must still work.
      await mount(
        tester,
        state,
        page: ProviderSettingsPage(state, key: UniqueKey()),
      );
      final remove = find.byKey(const Key('remove-provider-key'));
      await tester.scrollUntilVisible(
        remove,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<TextButton>(remove).onPressed, isNotNull);
      keys.failDelete = false;
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Удалить ключ'));
      await tester.pumpAndSettle();
      expect(keys.values[CloudProvider.openai], isNull);
      expect(find.text('Ключ удалён.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('opening model picker fetches live IDs and supports search', (
    tester,
  ) async {
    final keys = MemoryKeys()..values[CloudProvider.openai] = 'test-key';
    final cloud = FakeCloud();
    final history = MemoryHistory(
      ChatArchive(
        selectedModels: {CloudProvider.openai: 'saved-model'},
        catalogs: {
          CloudProvider.openai: ProviderCatalog(
            provider: CloudProvider.openai,
            modelIds: ['obsolete-cached-model'],
            fetchedAt: DateTime.utc(2020),
          ),
        },
      ),
    );
    final state = await chatState(keys: keys, history: history, cloud: cloud);
    await mount(tester, state);
    expect(cloud.modelRequests, isEmpty);
    await tester.tap(find.text('saved-model'));
    await tester.pumpAndSettle();
    expect(cloud.modelRequests, [CloudProvider.openai]);
    await tester.enterText(
      find.byKey(const Key('model-search')),
      'live-openai',
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('live-openai-model'),
      150,
      scrollable: sheetScroll(),
    );
    expect(find.text('obsolete-cached-model'), findsNothing);
    await tester.tap(find.text('live-openai-model'));
    await tester.pumpAndSettle();
    expect(state.selectedModel, 'live-openai-model');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'history search matches message content and provider changes need a new chat',
    (tester) async {
      final first = thread(
        'one',
        'Project planning',
        'unique satellite detail',
      );
      final second = thread('two', 'Other chat', 'nothing related');
      final keys = MemoryKeys()
        ..values.addAll({
          CloudProvider.openai: 'one-key',
          CloudProvider.zai: 'two-key',
        });
      final cloud = FakeCloud();
      final state = await chatState(
        keys: keys,
        cloud: cloud,
        history: MemoryHistory(
          ChatArchive(threads: [first, second], currentThreadId: first.id),
        ),
      );
      await mount(tester, state);
      await tester.tap(find.byTooltip('История чатов'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('history-search')),
        'satellite',
      );
      await tester.pumpAndSettle();
      expect(find.text('Project planning'), findsOneWidget);
      expect(find.text('Other chat'), findsNothing);
      await tester.tap(find.byTooltip('Закрыть историю'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('saved-model').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Z.AI'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('live-zai-model'),
        150,
        scrollable: sheetScroll(),
      );
      await tester.tap(find.text('live-zai-model'));
      await tester.pumpAndSettle();
      expect(state.currentThread!.id, first.id);
      expect(state.selectedProvider, CloudProvider.openai);
      expect(find.text('Создать чат'), findsOneWidget);
      await tester.tap(find.text('Создать чат'));
      await tester.pumpAndSettle();
      expect(state.currentThread, isNull);
      expect(state.selectedProvider, CloudProvider.zai);
      expect(state.threads, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Enter submits, streaming text survives stop, and fresh drafts survive completion',
    (tester) async {
      final keys = MemoryKeys()..values[CloudProvider.openai] = 'test-key';
      final cloud = FakeCloud();
      final state = await chatState(
        keys: keys,
        cloud: cloud,
        history: MemoryHistory(
          ChatArchive(selectedModels: {CloudProvider.openai: 'chosen-model'}),
        ),
      );
      await mount(tester, state);
      final composer = find.byKey(const Key('cloud-composer'));
      await tester.enterText(composer, 'Explain');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(cloud.requests, isEmpty);
      expect(
        tester.widget<TextField>(composer).controller!.text,
        contains('\n'),
      );
      await tester.enterText(composer, 'Explain satellites');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(cloud.requests, hasLength(1));
      expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
      cloud.controller!.add(
        const CloudChunk(
          textDelta: '**Partial** answer\n\n```python\nprint(42)\n```',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.text('print(42)'), findsOneWidget);
      await tester.enterText(composer, 'next draft');
      await tester.tap(find.byTooltip('Остановить ответ'));
      await tester.pumpAndSettle();
      expect(cloud.cancels, 1);
      expect(
        state.currentThread!.messages.last.status,
        ChatMessageStatus.stopped,
      );
      expect(find.text('Остановлено · неполный ответ'), findsOneWidget);
      expect(tester.widget<TextField>(composer).controller!.text, 'next draft');
      expect(find.byTooltip('Скопировать код'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Markdown code is copyable and images never become network widgets',
    (tester) async {
      final date = DateTime.utc(2026, 11, 17);
      final code = 'print("${List.filled(30, 'long_code').join('_')}")';
      final text =
          '# Можно начинать\n\nВот небольшой **пример**.\n\n'
          '![tracking](https://tracking.invalid/pixel.png)\n\n'
          '![local](file:///private/secret.png)\n\n```python\n$code\n```';
      final saved = ChatThread(
        id: 'markdown',
        title: 'Пример ответа',
        provider: CloudProvider.openai,
        model: 'selected-model',
        createdAt: date,
        updatedAt: date,
        messages: [
          ChatMessage(
            id: 'answer',
            role: 'assistant',
            text: text,
            provider: CloudProvider.openai,
            model: 'selected-model',
            createdAt: date,
          ),
        ],
      );
      final state = await chatState(
        history: MemoryHistory(
          ChatArchive(threads: [saved], currentThreadId: saved.id),
        ),
      );
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await mount(tester, state);
      final copy = find.byTooltip('Скопировать код');
      await tester.scrollUntilVisible(
        copy,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('Изображение: tracking'), findsOneWidget);
      expect(find.text('Изображение: local'), findsOneWidget);
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(copied, code);
      expect(tester.takeException(), isNull);
    },
  );
}
