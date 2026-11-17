import 'dart:async';
import 'dart:convert';

import 'package:axiom_edge/chat/chat_models.dart';
import 'package:axiom_edge/chat/chat_state.dart';
import 'package:axiom_edge/chat/chat_store.dart';
import 'package:axiom_edge/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

const _secret = 'sk-state-test-secret-key';
final _time = DateTime.utc(2026, 11, 17, 9);

ChatArchive _empty({bool model = true}) => ChatArchive(
  selectedModels: model ? const {CloudProvider.openai: 'model-a'} : const {},
);

class _MemoryStore implements ChatPersistence {
  _MemoryStore([ChatArchive? archive]) : saved = archive ?? _empty();

  ChatArchive saved;
  final committed = <ChatArchive>[];
  Future<void> Function(ChatArchive snapshot)? beforeSave;
  bool fail = false;
  var loads = 0;
  Future<void> _tail = Future.value();

  @override
  Future<ChatArchive> load() async {
    loads++;
    return saved;
  }

  @override
  Future<void> save(ChatArchive archive) {
    final snapshot = ChatArchive.fromJson(
      jsonDecode(jsonEncode(archive.toJson())) as Map<String, dynamic>,
    );
    final operation = _tail.then((_) async {
      await beforeSave?.call(snapshot);
      if (fail) throw StateError('private native storage failure');
      saved = snapshot;
      committed.add(snapshot);
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> drain() => _tail;
}

class _MemoryVault implements ChatKeyVault {
  _MemoryVault({bool keys = true})
    : values = keys
          ? {
              CloudProvider.openai: _secret,
              CloudProvider.zai: 'zai-test-secret',
            }
          : {};

  final Map<CloudProvider, String> values;
  final reads = <CloudProvider>[];
  Future<void> Function(CloudProvider provider)? beforeRead;
  Future<void> Function(CloudProvider provider)? beforeWrite;

  @override
  Future<String?> read(CloudProvider provider) async {
    reads.add(provider);
    final captured = values[provider];
    await beforeRead?.call(provider);
    return captured;
  }

  @override
  Future<void> write(CloudProvider provider, String key) async {
    await beforeWrite?.call(provider);
    values[provider] = key;
  }

  @override
  Future<void> delete(CloudProvider provider) async {
    values.remove(provider);
  }
}

class _StreamCall {
  _StreamCall(this.provider, this.model, this.messages, this.systemPrompt);
  final CloudProvider provider;
  final String model;
  final List<ChatTurn> messages;
  final String systemPrompt;
  final controller = StreamController<CloudChunk>(sync: true);

  void emit(CloudChunk chunk) => controller.add(chunk);
  Future<void> finish([String text = 'Complete answer']) async {
    if (text.isNotEmpty) emit(CloudChunk(textDelta: text));
    emit(const CloudChunk(done: true));
    await controller.close();
  }
}

class _Gateway implements CloudGateway {
  final calls = <_StreamCall>[];
  final modelCalls = <CloudProvider>[];
  final modelKeys = <String>[];
  Future<List<String>> Function(CloudProvider provider, String key)? catalog;
  void Function()? beforeStream;
  var cancels = 0;
  bool closed = false;
  final _waiters = <int, Completer<void>>{};

  Future<void> waitForStreams(int count) {
    if (calls.length >= count) return Future.value();
    return (_waiters[count] ??= Completer<void>()).future;
  }

  @override
  Future<List<String>> listModels(CloudProvider provider, String apiKey) async {
    modelCalls.add(provider);
    modelKeys.add(apiKey);
    return catalog == null
        ? ['model-a', 'model-b']
        : catalog!(provider, apiKey);
  }

  @override
  Stream<CloudChunk> stream({
    required CloudProvider provider,
    required String apiKey,
    required String model,
    required List<ChatTurn> messages,
    String systemPrompt = '',
  }) {
    beforeStream?.call();
    final call = _StreamCall(provider, model, List.of(messages), systemPrompt);
    calls.add(call);
    for (final entry in _waiters.entries) {
      if (entry.key <= calls.length && !entry.value.isCompleted) {
        entry.value.complete();
      }
    }
    return call.controller.stream;
  }

  @override
  void cancel() => cancels++;

  @override
  void close() {
    closed = true;
    for (final call in calls) {
      if (!call.controller.isClosed) unawaited(call.controller.close());
    }
  }
}

Future<ChatState> _state({
  _MemoryStore? store,
  _MemoryVault? vault,
  _Gateway? gateway,
  Duration debounce = const Duration(milliseconds: 300),
  bool initialize = true,
}) async {
  final memory = store ?? _MemoryStore();
  final state = ChatState(
    store: memory,
    keyVault: vault ?? _MemoryVault(),
    gateway: gateway ?? _Gateway(),
    now: () => _time,
    streamSaveDebounce: debounce,
  );
  var disposed = false;
  // A listener detects disposal only through our explicit test flag below;
  // dispose twice is avoided by the helper used in the one disposal test.
  _disposals[state] = () {
    if (disposed) return;
    disposed = true;
    state.dispose();
  };
  addTearDown(() async {
    _disposals.remove(state)?.call();
    await memory.drain();
  });
  if (initialize) await state.init();
  return state;
}

final _disposals = <ChatState, void Function()>{};

ChatThread _thread(List<ChatMessage> messages) => ChatThread(
  id: 'thread-existing',
  title: 'Existing chat',
  provider: CloudProvider.openai,
  model: 'model-a',
  createdAt: _time,
  updatedAt: _time,
  messages: messages,
);

ChatMessage _message(
  String id,
  String role,
  String text, {
  ChatMessageStatus status = ChatMessageStatus.complete,
  String reasoning = '',
}) => ChatMessage(
  id: id,
  role: role,
  text: text,
  reasoning: reasoning,
  status: status,
  provider: CloudProvider.openai,
  model: 'model-a',
  createdAt: _time,
);

void main() {
  test(
    'initialization reads history and vault without contacting providers',
    () async {
      final store = _MemoryStore();
      final vault = _MemoryVault();
      final gateway = _Gateway();
      final state = await _state(store: store, vault: vault, gateway: gateway);
      await state.init();
      expect(state.initialized, isTrue);
      expect(store.loads, 1);
      expect(vault.reads, CloudProvider.values);
      expect(gateway.calls, isEmpty);
      expect(gateway.modelCalls, isEmpty);
      expect(store.committed, isEmpty);
    },
  );

  test(
    'restart normalizes interrupted streaming messages and persists recovery',
    () async {
      final thread = _thread([
        _message('u', 'user', 'Question'),
        _message(
          'a',
          'assistant',
          'Partial',
          status: ChatMessageStatus.streaming,
          reasoning: 'Private reasoning',
        ),
      ]);
      final store = _MemoryStore(
        _empty().copyWith(threads: [thread], currentThreadId: thread.id),
      );
      final gateway = _Gateway();
      final state = await _state(store: store, gateway: gateway);
      expect(
        state.currentThread!.messages.last.status,
        ChatMessageStatus.stopped,
      );
      expect(state.currentThread!.messages.last.text, 'Partial');
      expect(state.currentThread!.messages.last.reasoning, 'Private reasoning');
      expect(
        store.saved.threads.single.messages.last.status,
        ChatMessageStatus.stopped,
      );
      expect(gateway.calls, isEmpty);
    },
  );

  test(
    'user and placeholder are durable before stream; reasoning stays separate',
    () async {
      final store = _MemoryStore();
      final gateway = _Gateway();
      gateway.beforeStream = () {
        final messages = store.saved.threads.single.messages;
        expect(messages.map((message) => message.role), ['user', 'assistant']);
        expect(messages.first.text, 'Hello');
        expect(messages.last.text, isEmpty);
        expect(messages.last.status, ChatMessageStatus.streaming);
      };
      final state = await _state(store: store, gateway: gateway);
      await state.updateSystemPrompt('Be precise');
      final pending = state.send('Hello');
      await gateway.waitForStreams(1);
      final call = gateway.calls.single;
      expect(call.systemPrompt, 'Be precise');
      expect(call.messages.map((turn) => turn.toJson()), [
        {'role': 'user', 'content': 'Hello'},
      ]);
      call.emit(
        const CloudChunk(
          textDelta: 'Public answer',
          reasoningDelta: 'Reasoning only',
        ),
      );
      await call.finish('');
      expect(await pending, isTrue);
      final assistant = state.currentThread!.messages.last;
      expect(assistant.text, 'Public answer');
      expect(assistant.reasoning, 'Reasoning only');
      expect(assistant.status, ChatMessageStatus.complete);
      expect(state.generating, isFalse);
      expect(state.error, isNull);
      expect(
        store.saved.threads.single.messages.last.toJson(),
        assistant.toJson(),
      );
    },
  );

  test('missing key or missing model blocks all generation calls', () async {
    final noKeyGateway = _Gateway();
    final noKey = await _state(
      vault: _MemoryVault(keys: false),
      gateway: noKeyGateway,
    );
    expect(await noKey.send('Question'), isFalse);
    expect(noKey.error, contains('API-ключ'));
    expect(noKeyGateway.calls, isEmpty);
    final noModelGateway = _Gateway();
    final noModel = await _state(
      store: _MemoryStore(_empty(model: false)),
      gateway: noModelGateway,
    );
    expect(await noModel.send('Question'), isFalse);
    expect(noModel.error, contains('модель'));
    expect(noModelGateway.calls, isEmpty);
  });

  test(
    'failed initial save preserves draft and sends no provider request',
    () async {
      final store = _MemoryStore();
      final gateway = _Gateway();
      final state = await _state(store: store, gateway: gateway);
      state.setDraft('Unsent question');
      store.fail = true;
      expect(await state.send('Unsent question'), isFalse);
      expect(state.draft, 'Unsent question');
      expect(state.threads, isEmpty);
      expect(state.generating, isFalse);
      expect(state.storageError, isNotNull);
      expect(gateway.calls, isEmpty);
    },
  );

  for (final action in ['stop', 'remove-key', 'dispose']) {
    test(
      '$action during initial save prevents a later provider request',
      () async {
        final store = _MemoryStore();
        final gateway = _Gateway();
        final state = await _state(store: store, gateway: gateway);
        final started = Completer<void>();
        final gate = Completer<void>();
        var held = false;
        store.beforeSave = (snapshot) async {
          if (!held && snapshot.threads.isNotEmpty) {
            held = true;
            started.complete();
            await gate.future;
          }
        };
        final send = state.send('Question');
        await started.future;
        Future<void>? removal;
        if (action == 'stop') state.stop();
        if (action == 'remove-key') {
          removal = state.removeKey(CloudProvider.openai);
        }
        if (action == 'dispose') _disposals[state]!();
        var flushed = false;
        final flushing = state.flush().then((_) => flushed = true);
        await Future<void>.delayed(Duration.zero);
        expect(flushed, isFalse);
        expect(gateway.calls, isEmpty);
        gate.complete();
        expect(await send, isTrue);
        await removal;
        await flushing;
        await store.drain();
        expect(gateway.calls, isEmpty);
        expect(state.generating, isFalse);
        expect(
          store.saved.threads.single.messages.last.status,
          ChatMessageStatus.stopped,
        );
      },
    );
  }

  test(
    'draft typed while initial save waits survives the committed send',
    () async {
      final store = _MemoryStore();
      final gateway = _Gateway();
      final state = await _state(store: store, gateway: gateway);
      final started = Completer<void>();
      final gate = Completer<void>();
      var held = false;
      store.beforeSave = (snapshot) async {
        if (!held && snapshot.threads.isNotEmpty) {
          held = true;
          started.complete();
          await gate.future;
        }
      };
      state.setDraft('First question');
      final send = state.send('First question');
      await started.future;
      state.setDraft('Next thought');
      gate.complete();
      await gateway.waitForStreams(1);
      await gateway.calls.single.finish();
      expect(await send, isTrue);
      expect(state.draft, 'Next thought');
      expect(store.saved.threads.single.draft, 'Next thought');
    },
  );

  test('thread provenance stays pinned until a new chat is created', () async {
    final gateway = _Gateway();
    final state = await _state(gateway: gateway);
    final first = state.send('OpenAI question');
    await gateway.waitForStreams(1);
    await gateway.calls.first.finish();
    await first;
    final firstId = state.currentThread!.id;
    await state.selectModel(CloudProvider.zai, 'glm-test');
    expect(state.currentThread!.provider, CloudProvider.openai);
    expect(state.selectedModel, 'model-a');
    expect(state.error, contains('закреплены'));
    await state.newChat(provider: CloudProvider.zai, model: 'glm-test');
    final second = state.send('Z.AI question');
    await gateway.waitForStreams(2);
    expect(gateway.calls.last.provider, CloudProvider.zai);
    expect(gateway.calls.last.model, 'glm-test');
    await gateway.calls.last.finish();
    await second;
    await state.openThread(firstId);
    expect(state.selectedProvider, CloudProvider.openai);
    expect(state.selectedModel, 'model-a');
    expect(state.threads, hasLength(2));
  });

  test(
    'context keeps stopped partial text and excludes blank failed text and reasoning',
    () async {
      final thread = _thread([
        _message('u', 'user', 'Old question'),
        _message(
          'a',
          'assistant',
          'Stopped partial',
          status: ChatMessageStatus.stopped,
          reasoning: 'Never send this reasoning',
        ),
        _message('blank', 'assistant', '   ', status: ChatMessageStatus.failed),
      ]);
      final gateway = _Gateway();
      final state = await _state(
        store: _MemoryStore(
          _empty().copyWith(threads: [thread], currentThreadId: thread.id),
        ),
        gateway: gateway,
      );
      final send = state.send('Next question');
      await gateway.waitForStreams(1);
      expect(gateway.calls.single.messages.map((turn) => turn.toJson()), [
        {'role': 'user', 'content': 'Old question'},
        {'role': 'assistant', 'content': 'Stopped partial'},
        {'role': 'user', 'content': 'Next question'},
      ]);
      await gateway.calls.single.finish();
      await send;
    },
  );

  test(
    'stream failure retains partial text, redacts keys and retry does not duplicate user',
    () async {
      final gateway = _Gateway();
      final state = await _state(gateway: gateway);
      final send = state.send('Question once');
      await gateway.waitForStreams(1);
      final failedCall = gateway.calls.single;
      failedCall.emit(
        const CloudChunk(
          textDelta: 'Partial answer',
          reasoningDelta: 'Only reasoning',
        ),
      );
      failedCall.controller.addError(
        StateError('Bearer $_secret; provider echoed $_secret'),
      );
      await failedCall.controller.close();
      expect(await send, isTrue);
      final interrupted = state.currentThread!.messages.last;
      expect(interrupted.status, ChatMessageStatus.failed);
      expect(interrupted.text, 'Partial answer');
      expect(interrupted.error, isNot(contains(_secret)));
      expect(state.error, isNot(contains(_secret)));
      final retry = state.retry();
      await gateway.waitForStreams(2);
      expect(gateway.calls.last.messages.map((turn) => turn.toJson()), [
        {'role': 'user', 'content': 'Question once'},
      ]);
      await gateway.calls.last.finish('Retried answer');
      expect(await retry, isTrue);
      expect(
        state.currentThread!.messages.where(
          (message) => message.role == 'user',
        ),
        hasLength(1),
      );
      expect(state.currentThread!.messages.last.text, 'Retried answer');
      expect(
        state.currentThread!.messages.last.status,
        ChatMessageStatus.complete,
      );
      expect(state.error, isNull);
    },
  );

  test(
    'continuous streaming checkpoints partial text before the stream ends',
    () async {
      final store = _MemoryStore();
      final gateway = _Gateway();
      final state = await _state(
        store: store,
        gateway: gateway,
        debounce: const Duration(milliseconds: 20),
      );
      final pending = state.send('Long question');
      await gateway.waitForStreams(1);
      final call = gateway.calls.single;
      for (var i = 0; i < 8; i++) {
        call.emit(CloudChunk(textDelta: '$i'));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await store.drain();
      expect(state.generating, isTrue);
      expect(call.controller.isClosed, isFalse);
      expect(store.committed.length, greaterThan(2));
      final checkpoint = store.saved.threads.single.messages.last;
      expect(checkpoint.status, ChatMessageStatus.streaming);
      expect(checkpoint.text, isNotEmpty);
      expect('01234567'.startsWith(checkpoint.text), isTrue);
      await call.finish('');
      await pending;
      expect(store.saved.threads.single.messages.last.text, '01234567');
    },
  );

  test(
    'catalog failure explicitly keeps stale cache without fake IDs or auto-selection',
    () async {
      final cached = ProviderCatalog(
        provider: CloudProvider.openai,
        modelIds: ['cached-real-id'],
        fetchedAt: _time,
      );
      final gateway = _Gateway()
        ..catalog = (_, _) async => throw StateError('catalog secret $_secret');
      final state = await _state(
        store: _MemoryStore(
          _empty(
            model: false,
          ).copyWith(catalogs: {CloudProvider.openai: cached}),
        ),
        gateway: gateway,
      );
      await state.refreshModels();
      expect(state.catalogs[CloudProvider.openai]!.modelIds, [
        'cached-real-id',
      ]);
      expect(state.catalogs[CloudProvider.openai]!.fallback, isTrue);
      expect(state.catalogs[CloudProvider.openai]!.isStale, isTrue);
      expect(state.selectedModel, isEmpty);
      expect(state.catalogError, isNotNull);
      expect(state.catalogError, isNot(contains(_secret)));
      await state.newChat(provider: CloudProvider.zai);
      await state.refreshModels();
      expect(state.catalogs[CloudProvider.zai]!.modelIds, isEmpty);
      expect(state.catalogs[CloudProvider.zai]!.fallback, isTrue);
      expect(state.selectedModel, isEmpty);
    },
  );

  test(
    'catalog loading and errors remain attached to their provider',
    () async {
      final openai = Completer<List<String>>();
      final zai = Completer<List<String>>();
      final gateway = _Gateway()
        ..catalog = (provider, _) =>
            provider == CloudProvider.openai ? openai.future : zai.future;
      final state = await _state(
        store: _MemoryStore(_empty(model: false)),
        gateway: gateway,
      );
      final first = state.refreshModels(CloudProvider.openai);
      final second = state.refreshModels(CloudProvider.zai);
      expect(state.isModelsLoading(CloudProvider.openai), isTrue);
      expect(state.isModelsLoading(CloudProvider.zai), isTrue);
      await state.newChat(provider: CloudProvider.zai);
      expect(state.modelsLoading, isTrue);
      openai.completeError(StateError('OpenAI catalog unavailable'));
      await first;
      expect(state.catalogErrorFor(CloudProvider.openai), isNotNull);
      expect(state.catalogError, isNull);
      expect(state.modelsLoading, isTrue);
      zai.complete(['glm-b', 'glm-a', 'glm-a']);
      await second;
      expect(state.modelsLoading, isFalse);
      expect(state.isModelsLoading(CloudProvider.openai), isFalse);
      expect(state.catalogs[CloudProvider.zai]!.modelIds, ['glm-a', 'glm-b']);
      expect(state.selectedModel, isEmpty);
      expect(gateway.modelCalls, [CloudProvider.openai, CloudProvider.zai]);
    },
  );

  test(
    'a delayed initial key read cannot replace a freshly saved key',
    () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      final vault = _MemoryVault()
        ..beforeRead = (provider) async {
          if (provider == CloudProvider.openai) {
            started.complete();
            await gate.future;
          }
        };
      final gateway = _Gateway();
      final state = await _state(
        vault: vault,
        gateway: gateway,
        initialize: false,
      );
      final initializing = state.init();
      await started.future;
      await state.saveKey(CloudProvider.openai, 'fresh-openai-key');
      gate.complete();
      await initializing;
      await state.refreshModels(CloudProvider.openai);
      expect(state.hasKey(CloudProvider.openai), isTrue);
      expect(gateway.modelKeys.single, 'fresh-openai-key');
      expect(vault.values[CloudProvider.openai], 'fresh-openai-key');
    },
  );

  test(
    'disposing during a key read does not repopulate in-memory keys',
    () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      final vault = _MemoryVault()
        ..beforeRead = (provider) async {
          if (provider == CloudProvider.openai) {
            started.complete();
            await gate.future;
          }
        };
      final gateway = _Gateway();
      final state = await _state(
        vault: vault,
        gateway: gateway,
        initialize: false,
      );
      final initializing = state.init();
      await started.future;
      _disposals[state]!();
      gate.complete();
      await initializing;
      expect(state.hasKey(CloudProvider.openai), isFalse);
      expect(state.hasKey(CloudProvider.zai), isFalse);
      expect(gateway.calls, isEmpty);
      expect(gateway.modelCalls, isEmpty);
    },
  );

  test(
    'disposing during a secure write cannot restore an in-memory key',
    () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      final vault = _MemoryVault(keys: false)
        ..beforeWrite = (provider) async {
          started.complete();
          await gate.future;
        };
      final state = await _state(vault: vault);
      final saving = state.saveKey(CloudProvider.openai, 'fresh-openai-key');
      await started.future;
      _disposals[state]!();
      gate.complete();
      await saving;
      expect(state.hasKey(CloudProvider.openai), isFalse);
    },
  );

  test(
    'removing a key queued behind a save leaves the secure vault empty',
    () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      final vault = _MemoryVault()
        ..beforeWrite = (provider) async {
          started.complete();
          await gate.future;
        };
      final gateway = _Gateway();
      final state = await _state(vault: vault, gateway: gateway);
      final saving = state.saveKey(CloudProvider.openai, 'fresh-openai-key');
      await started.future;
      final removing = state.removeKey(CloudProvider.openai);
      expect(state.hasKey(CloudProvider.openai), isFalse);
      gate.complete();
      await saving;
      await removing;
      expect(vault.values.containsKey(CloudProvider.openai), isFalse);
      expect(state.hasKey(CloudProvider.openai), isFalse);
      await state.refreshModels(CloudProvider.openai);
      expect(gateway.modelCalls, isEmpty);
    },
  );
}
