import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import 'chat_models.dart';
import 'chat_store.dart';
import 'cloud_api.dart';

class ChatState extends ChangeNotifier {
  ChatState({
    ChatPersistence? store,
    ChatKeyVault? keyVault,
    CloudGateway? gateway,
    DateTime Function()? now,
    String Function()? idFactory,
    this.streamSaveDebounce = const Duration(milliseconds: 300),
  }) : _store = store ?? ChatStore(),
       _keyVault = keyVault ?? SecureChatKeyVault(),
       _gateway = gateway ?? HttpCloudGateway(),
       _now = now ?? DateTime.now,
       _idFactory = idFactory;

  final ChatPersistence _store;
  final ChatKeyVault _keyVault;
  final CloudGateway _gateway;
  final DateTime Function() _now;
  final String Function()? _idFactory;
  final Duration streamSaveDebounce;
  final Map<CloudProvider, String> _keys = {};
  final Map<CloudProvider, int> _keyRevision = {};
  final Map<CloudProvider, Future<void>> _keyWrites = {};
  final Set<CloudProvider> _forgottenKeys = {};
  final Set<CloudProvider> _invalidatedCatalogs = {};
  final Set<CloudProvider> _loadingCatalogs = {};
  final Map<CloudProvider, String> _catalogErrors = {};
  ChatArchive _archive = ChatArchive.empty();
  Future<void>? _initializing;
  Timer? _saveTimer;
  _Request? _request;
  var _idCounter = 0;
  var _draftRevision = 0;
  var _writes = 0;
  var _historyReadable = false;
  var _disposed = false;

  bool initialized = false;
  bool generating = false;
  String? error;
  String? storageError;

  bool get modelsLoading => _loadingCatalogs.contains(selectedProvider);
  String? get catalogError => _catalogErrors[selectedProvider];
  bool isModelsLoading(CloudProvider provider) =>
      _loadingCatalogs.contains(provider);
  String? catalogErrorFor(CloudProvider provider) => _catalogErrors[provider];

  bool get saving => _writes > 0;
  CloudProvider get selectedProvider => _archive.selectedProvider;
  String get selectedModel =>
      currentThread?.model ?? _archive.selectedModels[selectedProvider] ?? '';
  Map<CloudProvider, ProviderCatalog> get catalogs => _archive.catalogs;
  List<ChatThread> get threads {
    final result = _archive.threads.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(result);
  }

  ChatThread? get currentThread {
    for (final thread in _archive.threads) {
      if (thread.id == _archive.currentThreadId) return thread;
    }
    return null;
  }

  String get draft => currentThread?.draft ?? _archive.newChatDraft;
  String get systemPrompt =>
      currentThread?.systemPrompt ?? _archive.newChatSystemPrompt;
  bool hasKey(CloudProvider provider) => _keys[provider]?.isNotEmpty ?? false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> init() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    var recovered = false;
    try {
      final saved = await _store.load();
      if (_disposed) return;
      final threads = saved.threads.map((thread) {
        final messages = thread.messages.map((message) {
          if (message.status != ChatMessageStatus.streaming) return message;
          recovered = true;
          return message.copyWith(status: ChatMessageStatus.stopped);
        }).toList();
        return thread.copyWith(messages: messages);
      }).toList();
      _archive = saved.copyWith(threads: threads);
      for (final provider in _invalidatedCatalogs) {
        _markCatalogStale(provider);
      }
      final current = currentThread;
      if (current != null) {
        _archive = _archive.copyWith(
          selectedProvider: current.provider,
          selectedModels: {
            ..._archive.selectedModels,
            current.provider: current.model,
          },
        );
      }
      _historyReadable = true;
    } catch (_) {
      if (_disposed) return;
      storageError =
          'Не удалось прочитать историю. Исходный файл сохранён; '
          'запись отключена, чтобы не потерять переписку.';
    }
    for (final provider in CloudProvider.values) {
      final revision = _keyRevision[provider] ?? 0;
      try {
        await (_keyWrites[provider] ?? Future<void>.value());
        if (_disposed) return;
        if (revision != (_keyRevision[provider] ?? 0) ||
            _forgottenKeys.contains(provider)) {
          continue;
        }
        final key = await _keyVault.read(provider);
        if (_disposed) return;
        if (revision != (_keyRevision[provider] ?? 0)) continue;
        if (key != null && key.trim().isNotEmpty) _keys[provider] = key.trim();
      } catch (_) {
        if (_disposed) return;
        error =
            'Не удалось открыть защищённое хранилище ключей. '
            'Сохранённые ключи не изменены.';
      }
    }
    initialized = true;
    if (recovered || _invalidatedCatalogs.isNotEmpty) {
      await _persist(notify: false);
    }
    notifyListeners();
  }

  Future<void> saveKey(CloudProvider provider, String value) async {
    if (_disposed) return;
    final key = value.trim();
    if (key.isEmpty) {
      error = 'Введи API-ключ.';
      notifyListeners();
      return;
    }
    final revision = (_keyRevision[provider] ?? 0) + 1;
    _keyRevision[provider] = revision;
    try {
      await _keyWrite(provider, () => _keyVault.write(provider, key));
      if (_disposed || revision != _keyRevision[provider]) return;
      _keys[provider] = key;
      _forgottenKeys.remove(provider);
      _markCatalogStale(provider);
      error = null;
      await _persistKeyMetadata();
    } catch (_) {
      if (_disposed || revision != _keyRevision[provider]) return;
      error = 'Не удалось сохранить ключ в защищённом хранилище.';
    }
    notifyListeners();
  }

  Future<void> removeKey(CloudProvider provider) async {
    if (_disposed) return;
    if (_request?.provider == provider) stop();
    _keys.remove(provider);
    _forgottenKeys.add(provider);
    _markCatalogStale(provider);
    final revision = (_keyRevision[provider] ?? 0) + 1;
    _keyRevision[provider] = revision;
    try {
      await _keyWrite(provider, () => _keyVault.delete(provider));
      if (_disposed || revision != _keyRevision[provider]) return;
      error = null;
    } catch (_) {
      if (_disposed || revision != _keyRevision[provider]) return;
      error =
          'Ключ убран из памяти, но удалить его из защищённого хранилища '
          'не удалось. Повтори удаление.';
    }
    await _persistKeyMetadata();
    notifyListeners();
  }

  Future<void> _persistKeyMetadata() async {
    if (!initialized) return;
    final pending = _request;
    if (pending != null && !pending.commitDone.isCompleted) {
      // Removing a credential must finish without waiting for an unrelated
      // slow history write. Its metadata still flushes after that commit.
      unawaited(_persist());
    } else {
      await _persist();
    }
  }

  void _markCatalogStale(CloudProvider provider) {
    _invalidatedCatalogs.add(provider);
    _catalogErrors.remove(provider);
    final previous = _archive.catalogs[provider];
    if (previous == null) return;
    _archive = _archive.copyWith(
      catalogs: {
        ..._archive.catalogs,
        provider: ProviderCatalog(
          provider: provider,
          modelIds: previous.modelIds,
          fetchedAt: previous.fetchedAt,
          fallback: true,
        ),
      },
    );
  }

  Future<void> _keyWrite(
    CloudProvider provider,
    Future<void> Function() operation,
  ) {
    final result = (_keyWrites[provider] ?? Future<void>.value()).then(
      (_) => operation(),
    );
    _keyWrites[provider] = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<bool> testConnection(CloudProvider provider) =>
      _refreshModels(provider);

  Future<void> refreshModels([CloudProvider? provider]) async {
    await _refreshModels(provider ?? selectedProvider);
  }

  Future<bool> _refreshModels(CloudProvider provider) async {
    if (!initialized ||
        _loadingCatalogs.contains(provider) ||
        generating ||
        _disposed) {
      return false;
    }
    final key = _keys[provider];
    if (key == null) {
      _catalogErrors[provider] = 'Сначала сохрани API-ключ ${provider.label}.';
      notifyListeners();
      return false;
    }
    _loadingCatalogs.add(provider);
    _catalogErrors.remove(provider);
    notifyListeners();
    final revision = _keyRevision[provider] ?? 0;
    try {
      final ids = (await _gateway.listModels(
        provider,
        key,
      )).where((id) => id.trim().isNotEmpty).toSet().toList()..sort();
      if (revision != (_keyRevision[provider] ?? 0) || _disposed) return false;
      if (ids.isEmpty) {
        throw const CloudApiException(
          'Провайдер вернул пустой список моделей.',
          code: 'empty_models',
        );
      }
      _archive = _archive.copyWith(
        catalogs: {
          ..._archive.catalogs,
          provider: ProviderCatalog(
            provider: provider,
            modelIds: ids,
            fetchedAt: _now(),
          ),
        },
      );
      _invalidatedCatalogs.remove(provider);
      await _persist();
      return true;
    } catch (exception) {
      if (revision != (_keyRevision[provider] ?? 0) || _disposed) return false;
      _catalogErrors[provider] = _redact(exception);
      final previous = _archive.catalogs[provider];
      _archive = _archive.copyWith(
        catalogs: {
          ..._archive.catalogs,
          provider: ProviderCatalog(
            provider: provider,
            modelIds: previous?.modelIds ?? const [],
            fetchedAt: previous?.fetchedAt,
            fallback: true,
          ),
        },
      );
      await _persist();
      return false;
    } finally {
      _loadingCatalogs.remove(provider);
      notifyListeners();
    }
  }

  bool _readyToEdit() {
    if (_disposed) return false;
    if (!initialized || !_historyReadable) {
      error = storageError ?? 'История ещё загружается.';
      notifyListeners();
      return false;
    }
    if (generating) {
      error = 'Сначала останови текущий ответ.';
      notifyListeners();
      return false;
    }
    error = null;
    return true;
  }

  Future<void> selectModel(CloudProvider provider, String id) async {
    if (!_readyToEdit()) return;
    final model = id.trim();
    if (model.isEmpty) {
      error = 'Укажи модель.';
      notifyListeners();
      return;
    }
    final thread = currentThread;
    if (thread != null &&
        thread.messages.isNotEmpty &&
        (thread.provider != provider || thread.model != model)) {
      error = 'Провайдер и модель закреплены за перепиской. Создай новый чат.';
      notifyListeners();
      return;
    }
    _archive = _archive.copyWith(
      selectedProvider: provider,
      selectedModels: {..._archive.selectedModels, provider: model},
    );
    if (thread != null && thread.messages.isEmpty) {
      _putThread(thread.copyWith(provider: provider, model: model));
    }
    await _persist();
    notifyListeners();
  }

  Future<void> newChat({
    CloudProvider? provider,
    String? model,
    String systemPrompt = '',
  }) async {
    if (!_readyToEdit()) return;
    final selected = provider ?? selectedProvider;
    final id = (model ?? _archive.selectedModels[selected] ?? '').trim();
    _archive = _archive.copyWith(
      selectedProvider: selected,
      selectedModels: {
        ..._archive.selectedModels,
        if (id.isNotEmpty) selected: id,
      },
      clearCurrentThread: true,
      newChatDraft: '',
      newChatSystemPrompt: systemPrompt,
    );
    await _persist();
    notifyListeners();
  }

  Future<void> openThread(String id) async {
    if (!_readyToEdit()) return;
    final thread = _thread(id);
    if (thread == null) return;
    _archive = _archive.copyWith(
      currentThreadId: id,
      selectedProvider: thread.provider,
      selectedModels: {
        ..._archive.selectedModels,
        thread.provider: thread.model,
      },
    );
    await _persist();
    notifyListeners();
  }

  Future<void> deleteThread(String id) async {
    if (!_readyToEdit()) return;
    _archive = _archive.copyWith(
      threads: _archive.threads.where((thread) => thread.id != id),
      clearCurrentThread: _archive.currentThreadId == id,
    );
    await _persist();
    notifyListeners();
  }

  Future<void> renameThread(String id, String title) async {
    if (!_readyToEdit()) return;
    final thread = _thread(id);
    if (thread == null || title.trim().isEmpty) return;
    _putThread(thread.copyWith(title: title.trim(), updatedAt: _now()));
    await _persist();
    notifyListeners();
  }

  Future<void> updateSystemPrompt(String value) async {
    if (!_readyToEdit()) return;
    final thread = currentThread;
    if (thread == null) {
      _archive = _archive.copyWith(newChatSystemPrompt: value);
    } else {
      _putThread(thread.copyWith(systemPrompt: value, updatedAt: _now()));
    }
    await _persist();
    notifyListeners();
  }

  void setDraft(String value) {
    if (!initialized || !_historyReadable || _disposed) return;
    _draftRevision++;
    final thread = currentThread;
    if (thread == null) {
      _archive = _archive.copyWith(newChatDraft: value);
    } else {
      _putThread(thread.copyWith(draft: value));
    }
    _scheduleSave();
    notifyListeners();
  }

  Future<bool> send(String value) async {
    if (!_readyToEdit()) return false;
    final text = value.trim();
    if (text.isEmpty) return false;
    final provider = currentThread?.provider ?? selectedProvider;
    final model = selectedModel;
    if (!_validateSend(provider, model)) return false;
    final time = _now();
    final thread =
        currentThread ??
        ChatThread(
          id: _id(),
          title: 'Новый чат',
          provider: provider,
          model: model,
          createdAt: time,
          updatedAt: time,
          systemPrompt: systemPrompt,
        );
    final user = ChatMessage(
      id: _id(),
      role: 'user',
      text: text,
      provider: provider,
      model: model,
      createdAt: time,
    );
    return _generate(thread, [...thread.messages, user], clearDraft: true);
  }

  Future<bool> retry() => _repeat(onlyInterrupted: true);
  Future<bool> regenerate() => _repeat(onlyInterrupted: false);

  Future<bool> _repeat({required bool onlyInterrupted}) async {
    if (!_readyToEdit()) return false;
    final thread = currentThread;
    if (thread == null || thread.messages.isEmpty) return false;
    if (!_validateSend(thread.provider, thread.model)) return false;
    final base = thread.messages.toList();
    if (base.last.role == 'assistant') {
      if (onlyInterrupted && base.last.status == ChatMessageStatus.complete) {
        error =
            'Ответ уже завершён. Для нового варианта выбери повторную генерацию.';
        notifyListeners();
        return false;
      }
      base.removeLast();
    }
    if (base.isEmpty || base.last.role != 'user') return false;
    return _generate(thread, base);
  }

  bool _validateSend(CloudProvider provider, String model) {
    if (!hasKey(provider)) {
      error = 'Добавь API-ключ ${provider.label}.';
    } else if (model.isEmpty) {
      error = 'Выбери модель или укажи её ID вручную.';
    } else {
      return true;
    }
    notifyListeners();
    return false;
  }

  Future<bool> _generate(
    ChatThread thread,
    List<ChatMessage> base, {
    bool clearDraft = false,
  }) async {
    final apiKey = _keys[thread.provider]!;
    final request = _Request(thread.id, _id(), thread.provider);
    _request = request;
    final draftRevision = _draftRevision;
    generating = true;
    error = null;
    notifyListeners();
    _saveTimer?.cancel();
    final assistant = ChatMessage(
      id: request.assistantId,
      role: 'assistant',
      text: '',
      provider: thread.provider,
      model: thread.model,
      createdAt: _now(),
      status: ChatMessageStatus.streaming,
    );
    final nextThread = thread.copyWith(
      title: thread.messages.isEmpty
          ? String.fromCharCodes(base.first.text.runes.take(60))
          : thread.title,
      draft: clearDraft ? '' : thread.draft,
      updatedAt: _now(),
      messages: [...base, assistant],
    );
    final candidate = _withThread(_archive, nextThread).copyWith(
      currentThreadId: thread.id,
      selectedProvider: thread.provider,
      newChatDraft: clearDraft ? '' : _archive.newChatDraft,
    );
    final persisted = await _persist(snapshot: candidate, notify: false);
    if (!persisted) {
      request.commitDone.complete();
      _request = null;
      generating = false;
      notifyListeners();
      return false;
    }
    // Draft typing or a catalog response can arrive while the initial write
    // is pending. Merge the committed messages into the newest local settings.
    final latestDraft = _draftRevision != draftRevision
        ? draft
        : nextThread.draft;
    _archive = _withThread(_archive, nextThread.copyWith(draft: latestDraft))
        .copyWith(
          currentThreadId: thread.id,
          selectedProvider: thread.provider,
          newChatDraft: clearDraft ? '' : _archive.newChatDraft,
        );
    request.committed = true;
    request.commitDone.complete();
    _scheduleSave();
    notifyListeners();
    try {
      if (request.cancelled || _disposed) {
        request.cancelled = true;
        return true;
      }
      // Only committed history is submitted; reasoning and empty placeholders
      // are never passed as assistant messages.
      final context = base
          .where(
            (message) =>
                message.text.trim().isNotEmpty &&
                message.status != ChatMessageStatus.streaming,
          )
          .map((message) => ChatTurn(message.role, message.text))
          .toList();
      request.subscription = _gateway
          .stream(
            provider: thread.provider,
            apiKey: apiKey,
            model: thread.model,
            messages: context,
            systemPrompt: thread.systemPrompt,
          )
          .listen(
            (chunk) {
              if (request.cancelled || _disposed) return;
              _updateAssistant(
                request,
                (message) => message.copyWith(
                  text: message.text + chunk.textDelta,
                  reasoning: message.reasoning + chunk.reasoningDelta,
                ),
              );
              request.sawDone = request.sawDone || chunk.done;
              _scheduleSave();
              notifyListeners();
            },
            onError: (Object exception) {
              request.failure = _redact(exception);
              if (!request.done.isCompleted) request.done.complete();
            },
            onDone: () {
              if (!request.done.isCompleted) request.done.complete();
            },
            cancelOnError: true,
          );
      await request.done.future;
      if (!request.cancelled && request.failure == null && !request.sawDone) {
        request.failure = 'Соединение оборвалось до завершения ответа.';
      }
    } catch (exception) {
      request.failure = _redact(exception);
    } finally {
      _saveTimer?.cancel();
      final message = _thread(request.threadId)?.messages
          .where((message) => message.id == request.assistantId)
          .firstOrNull;
      if (!request.cancelled &&
          request.failure == null &&
          (message?.text.trim().isEmpty ?? true)) {
        request.failure = 'Провайдер не вернул текст ответа.';
      }
      _updateAssistant(
        request,
        (message) => message.copyWith(
          status: request.cancelled
              ? ChatMessageStatus.stopped
              : request.failure == null
              ? ChatMessageStatus.complete
              : ChatMessageStatus.failed,
          error: request.cancelled ? null : request.failure,
          clearError: request.cancelled || request.failure == null,
        ),
      );
      error = request.cancelled ? null : request.failure;
      _request = null;
      generating = false;
      await _persist();
      notifyListeners();
    }
    return true;
  }

  void stop() {
    final request = _request;
    if (request == null || request.cancelled) return;
    request.cancelled = true;
    _updateAssistant(
      request,
      (message) =>
          message.copyWith(status: ChatMessageStatus.stopped, clearError: true),
    );
    if (request.committed) {
      try {
        _gateway.cancel();
      } catch (_) {
        /* Partial text is retained. */
      }
    }
    final cancellation = request.subscription?.cancel();
    if (cancellation != null) unawaited(cancellation.catchError((Object _) {}));
    if (!request.done.isCompleted) request.done.complete();
    _saveTimer?.cancel();
    unawaited(_persist());
    notifyListeners();
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    if (_historyReadable && initialized) await _persist();
  }

  void _scheduleSave() {
    if (_request != null && !_request!.commitDone.isCompleted) return;
    if (_saveTimer?.isActive ?? false) return;
    _saveTimer = Timer(streamSaveDebounce, () => unawaited(_persist()));
  }

  Future<bool> _persist({ChatArchive? snapshot, bool notify = true}) async {
    if (!_historyReadable) return false;
    final pending = _request;
    if (snapshot == null &&
        pending != null &&
        !pending.commitDone.isCompleted) {
      await pending.commitDone.future;
    }
    _writes++;
    if (notify) notifyListeners();
    try {
      await _store.save(snapshot ?? _archive);
      storageError = null;
      return true;
    } catch (_) {
      storageError =
          'Не удалось сохранить переписку. Текущий текст остаётся '
          'в памяти; проверь свободное место и повтори сохранение.';
      return false;
    } finally {
      _writes--;
      if (notify) notifyListeners();
    }
  }

  ChatThread? _thread(String id) =>
      _archive.threads.where((thread) => thread.id == id).firstOrNull;

  void _putThread(ChatThread thread) =>
      _archive = _withThread(_archive, thread);

  ChatArchive _withThread(ChatArchive archive, ChatThread thread) =>
      archive.copyWith(
        threads: [
          ...archive.threads.where((entry) => entry.id != thread.id),
          thread,
        ],
      );

  void _updateAssistant(
    _Request request,
    ChatMessage Function(ChatMessage) update,
  ) {
    final thread = _thread(request.threadId);
    if (thread == null) return;
    _putThread(
      thread.copyWith(
        updatedAt: _now(),
        messages: thread.messages.map(
          (message) =>
              message.id == request.assistantId ? update(message) : message,
        ),
      ),
    );
  }

  String _id() =>
      _idFactory?.call() ??
      '${_now().toUtc().microsecondsSinceEpoch}-${_idCounter++}';

  String _redact(Object exception) {
    // Only the transport's deliberately public exceptions may supply detail.
    // Arbitrary platform errors can contain headers, request bodies or paths.
    var value = exception is CloudApiException
        ? exception.message
        : 'Не удалось выполнить запрос. Проверь соединение и настройки провайдера.';
    for (final key in _keys.values) {
      value = value.replaceAll(key, '[скрыто]');
    }
    value = value
        .replaceAll(
          RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
          'Bearer [скрыто]',
        )
        .replaceAll(RegExp(r'\bsk-[A-Za-z0-9_-]{6,}'), '[скрыто]');
    return value.length > 400 ? '${value.substring(0, 400)}…' : value;
  }

  @override
  void dispose() {
    stop();
    _saveTimer?.cancel();
    if (_historyReadable) unawaited(_persist(notify: false));
    _disposed = true;
    _gateway.close();
    _keys.clear();
    super.dispose();
  }
}

class _Request {
  _Request(this.threadId, this.assistantId, this.provider);
  final String threadId;
  final String assistantId;
  final CloudProvider provider;
  final done = Completer<void>();
  final commitDone = Completer<void>();
  StreamSubscription<CloudChunk>? subscription;
  bool cancelled = false;
  bool committed = false;
  bool sawDone = false;
  String? failure;
}
