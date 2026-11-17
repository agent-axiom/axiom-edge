import '../core/models.dart';

enum CloudProvider {
  openai,
  zai;

  String get label => switch (this) {
    openai => 'OpenAI',
    zai => 'Z.AI',
  };

  Uri get baseUri => Uri.parse(switch (this) {
    openai => 'https://api.openai.com/v1/',
    zai => 'https://api.z.ai/api/paas/v4/',
  });
}

class CloudChunk {
  const CloudChunk({
    this.textDelta = '',
    this.reasoningDelta = '',
    this.done = false,
    this.finishReason,
    this.usage,
  });

  final String textDelta;
  final String reasoningDelta;
  final bool done;
  final String? finishReason;
  final Map<String, Object?>? usage;
}

abstract class CloudGateway {
  Future<List<String>> listModels(CloudProvider provider, String apiKey);
  Stream<CloudChunk> stream({
    required CloudProvider provider,
    required String apiKey,
    required String model,
    required List<ChatTurn> messages,
    String systemPrompt = '',
  });
  void cancel();
  void close();
}

enum ChatMessageStatus { complete, streaming, stopped, failed }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.provider,
    required this.model,
    required this.createdAt,
    this.reasoning = '',
    this.status = ChatMessageStatus.complete,
    this.error,
  });

  final String id;
  final String role;
  final String text;
  final String reasoning;
  final ChatMessageStatus status;
  final String? error;
  final CloudProvider provider;
  final String model;
  final DateTime createdAt;

  ChatMessage copyWith({
    String? text,
    String? reasoning,
    ChatMessageStatus? status,
    String? error,
    bool clearError = false,
  }) => ChatMessage(
    id: id,
    role: role,
    text: text ?? this.text,
    reasoning: reasoning ?? this.reasoning,
    status: status ?? this.status,
    error: clearError ? null : error ?? this.error,
    provider: provider,
    model: model,
    createdAt: createdAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'role': role,
    'text': text,
    'reasoning': reasoning,
    'status': status.name,
    'error': error,
    'provider': provider.name,
    'model': model,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  factory ChatMessage.fromJson(Map<String, dynamic> value) {
    final role = _text(value, 'role');
    if (role != 'user' && role != 'assistant') {
      throw const FormatException('Unsupported chat role');
    }
    return ChatMessage(
      id: _text(value, 'id'),
      role: role,
      text: _text(value, 'text', allowEmpty: true),
      reasoning: _optionalText(value, 'reasoning'),
      status: _enumValue(ChatMessageStatus.values, value['status'], 'status'),
      error: _nullableText(value, 'error'),
      provider: _enumValue(CloudProvider.values, value['provider'], 'provider'),
      model: _text(value, 'model'),
      createdAt: _date(value, 'created_at'),
    );
  }
}

class ChatThread {
  ChatThread({
    required this.id,
    required this.title,
    required this.provider,
    required this.model,
    required this.createdAt,
    required this.updatedAt,
    this.systemPrompt = '',
    this.draft = '',
    Iterable<ChatMessage> messages = const [],
  }) : messages = List.unmodifiable(messages);

  final String id;
  final String title;
  final CloudProvider provider;
  final String model;
  final String systemPrompt;
  final String draft;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ChatMessage> messages;

  ChatThread copyWith({
    String? title,
    CloudProvider? provider,
    String? model,
    String? systemPrompt,
    String? draft,
    DateTime? updatedAt,
    Iterable<ChatMessage>? messages,
  }) => ChatThread(
    id: id,
    title: title ?? this.title,
    provider: provider ?? this.provider,
    model: model ?? this.model,
    systemPrompt: systemPrompt ?? this.systemPrompt,
    draft: draft ?? this.draft,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    messages: messages ?? this.messages,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'provider': provider.name,
    'model': model,
    'system_prompt': systemPrompt,
    'draft': draft,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'messages': messages.map((message) => message.toJson()).toList(),
  };

  factory ChatThread.fromJson(Map<String, dynamic> value) {
    final provider = _enumValue(
      CloudProvider.values,
      value['provider'],
      'provider',
    );
    final model = _text(value, 'model');
    final messages = _objects(
      value,
      'messages',
    ).map(ChatMessage.fromJson).toList();
    final ids = <String>{};
    for (final message in messages) {
      if (message.provider != provider ||
          message.model != model ||
          !ids.add(message.id)) {
        throw const FormatException('Inconsistent chat provenance');
      }
    }
    return ChatThread(
      id: _text(value, 'id'),
      title: _text(value, 'title', allowEmpty: true),
      provider: provider,
      model: model,
      systemPrompt: _optionalText(value, 'system_prompt'),
      draft: _optionalText(value, 'draft'),
      createdAt: _date(value, 'created_at'),
      updatedAt: _date(value, 'updated_at'),
      messages: messages,
    );
  }
}

class ProviderCatalog {
  ProviderCatalog({
    required this.provider,
    Iterable<String> modelIds = const [],
    this.fetchedAt,
    this.fallback = false,
  }) : modelIds = List.unmodifiable(modelIds);

  final CloudProvider provider;
  final List<String> modelIds;
  final DateTime? fetchedAt;
  final bool fallback;

  bool get isStale => staleAt(DateTime.now());
  bool staleAt(DateTime now) =>
      fallback ||
      fetchedAt == null ||
      now.toUtc().difference(fetchedAt!.toUtc()) >= const Duration(hours: 24);

  Map<String, Object?> toJson() => {
    'provider': provider.name,
    'model_ids': modelIds,
    'fetched_at': fetchedAt?.toUtc().toIso8601String(),
    'fallback': fallback,
  };

  factory ProviderCatalog.fromJson(Map<String, dynamic> value) {
    final ids = value['model_ids'];
    if (ids is! List || ids.any((id) => id is! String || id.trim().isEmpty)) {
      throw const FormatException('Invalid model catalog');
    }
    if (value['fallback'] is! bool) {
      throw const FormatException('Invalid model catalog fallback');
    }
    return ProviderCatalog(
      provider: _enumValue(CloudProvider.values, value['provider'], 'provider'),
      modelIds: ids.cast<String>().toSet(),
      fetchedAt: value['fetched_at'] == null
          ? null
          : _date(value, 'fetched_at'),
      fallback: value['fallback'] as bool,
    );
  }
}

class ChatArchive {
  ChatArchive({
    Iterable<ChatThread> threads = const [],
    Map<CloudProvider, ProviderCatalog> catalogs = const {},
    this.selectedProvider = CloudProvider.openai,
    Map<CloudProvider, String> selectedModels = const {},
    this.currentThreadId,
    this.newChatDraft = '',
    this.newChatSystemPrompt = '',
  }) : threads = List.unmodifiable(threads),
       catalogs = Map.unmodifiable(catalogs),
       selectedModels = Map.unmodifiable(selectedModels);

  factory ChatArchive.empty() => ChatArchive();

  final List<ChatThread> threads;
  final Map<CloudProvider, ProviderCatalog> catalogs;
  final CloudProvider selectedProvider;
  final Map<CloudProvider, String> selectedModels;
  final String? currentThreadId;
  final String newChatDraft;
  final String newChatSystemPrompt;

  ChatArchive copyWith({
    Iterable<ChatThread>? threads,
    Map<CloudProvider, ProviderCatalog>? catalogs,
    CloudProvider? selectedProvider,
    Map<CloudProvider, String>? selectedModels,
    String? currentThreadId,
    bool clearCurrentThread = false,
    String? newChatDraft,
    String? newChatSystemPrompt,
  }) => ChatArchive(
    threads: threads ?? this.threads,
    catalogs: catalogs ?? this.catalogs,
    selectedProvider: selectedProvider ?? this.selectedProvider,
    selectedModels: selectedModels ?? this.selectedModels,
    currentThreadId: clearCurrentThread
        ? null
        : currentThreadId ?? this.currentThreadId,
    newChatDraft: newChatDraft ?? this.newChatDraft,
    newChatSystemPrompt: newChatSystemPrompt ?? this.newChatSystemPrompt,
  );

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'threads': threads.map((thread) => thread.toJson()).toList(),
    'catalogs': {
      for (final entry in catalogs.entries)
        entry.key.name: entry.value.toJson(),
    },
    'selected_provider': selectedProvider.name,
    'selected_models': {
      for (final entry in selectedModels.entries) entry.key.name: entry.value,
    },
    'current_thread_id': currentThreadId,
    'new_chat_draft': newChatDraft,
    'new_chat_system_prompt': newChatSystemPrompt,
  };

  factory ChatArchive.fromJson(Map<String, dynamic> value) {
    if (value['schema_version'] != 1) {
      throw const FormatException('Unsupported chat history version');
    }
    final threads = _objects(
      value,
      'threads',
    ).map(ChatThread.fromJson).toList();
    final ids = <String>{};
    for (final thread in threads) {
      if (!ids.add(thread.id)) {
        throw const FormatException('Duplicate thread ID');
      }
    }
    final current = _nullableText(value, 'current_thread_id');
    if (current != null && !ids.contains(current)) {
      throw const FormatException('Current chat is missing');
    }
    final rawCatalogs = _object(value['catalogs']);
    final catalogs = <CloudProvider, ProviderCatalog>{};
    for (final entry in rawCatalogs.entries) {
      final provider = _enumValue(CloudProvider.values, entry.key, 'provider');
      final catalog = ProviderCatalog.fromJson(_object(entry.value));
      if (provider != catalog.provider) {
        throw const FormatException('Inconsistent catalog provider');
      }
      catalogs[provider] = catalog;
    }
    final selected = <CloudProvider, String>{};
    for (final entry in _object(value['selected_models']).entries) {
      if (entry.value is! String || (entry.value as String).trim().isEmpty) {
        throw const FormatException('Invalid selected model');
      }
      selected[_enumValue(CloudProvider.values, entry.key, 'provider')] =
          entry.value as String;
    }
    return ChatArchive(
      threads: threads,
      catalogs: catalogs,
      selectedProvider: _enumValue(
        CloudProvider.values,
        value['selected_provider'],
        'provider',
      ),
      selectedModels: selected,
      currentThreadId: current,
      newChatDraft: _optionalText(value, 'new_chat_draft'),
      newChatSystemPrompt: _optionalText(value, 'new_chat_system_prompt'),
    );
  }
}

String _text(
  Map<String, dynamic> value,
  String key, {
  bool allowEmpty = false,
}) {
  final text = value[key];
  if (text is! String || (!allowEmpty && text.trim().isEmpty)) {
    throw FormatException('Invalid chat field: $key');
  }
  return text;
}

String _optionalText(Map<String, dynamic> value, String key) {
  if (!value.containsKey(key)) return '';
  return _text(value, key, allowEmpty: true);
}

String? _nullableText(Map<String, dynamic> value, String key) {
  if (value[key] == null) return null;
  return _text(value, key, allowEmpty: true);
}

DateTime _date(Map<String, dynamic> value, String key) {
  final parsed = DateTime.tryParse(_text(value, key));
  if (parsed == null) throw FormatException('Invalid chat date: $key');
  return parsed.toUtc();
}

T _enumValue<T extends Enum>(List<T> options, Object? raw, String field) {
  for (final option in options) {
    if (option.name == raw) return option;
  }
  throw FormatException('Invalid chat enum: $field');
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid chat object');
  }
  return value;
}

List<Map<String, dynamic>> _objects(Map<String, dynamic> value, String key) {
  final raw = value[key];
  if (raw is! List) throw FormatException('Invalid chat list: $key');
  return raw.map(_object).toList();
}
