import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:axiom_edge/chat/chat_models.dart';
import 'package:axiom_edge/chat/chat_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _MutableArchive extends ChatArchive {
  _MutableArchive(this.data);

  final Map<String, Object?> data;

  @override
  Map<String, Object?> toJson() => data;
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('axiom-chat-store-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  File history() => File(p.join(root.path, 'chat', 'history.json'));
  ChatStore store({
    Future<void> Function(File temporary, File destination)? replaceFile,
  }) => ChatStore(directory: () async => root, replaceFile: replaceFile);

  test(
    'restart preserves history, drafts, catalog and raw streaming state',
    () async {
      final date = DateTime.utc(2026, 11, 17, 9);
      final archive = ChatArchive(
        selectedProvider: CloudProvider.zai,
        selectedModels: const {CloudProvider.zai: 'glm-test'},
        currentThreadId: 'thread-1',
        newChatDraft: 'Unsent new-chat message',
        newChatSystemPrompt: 'New-chat instructions',
        catalogs: {
          CloudProvider.zai: ProviderCatalog(
            provider: CloudProvider.zai,
            modelIds: const ['glm-test', 'glm-other'],
            fetchedAt: date,
          ),
        },
        threads: [
          ChatThread(
            id: 'thread-1',
            title: 'Сохранённый диалог',
            provider: CloudProvider.zai,
            model: 'glm-test',
            systemPrompt: 'Be precise',
            draft: 'Unsent continuation',
            createdAt: date,
            updatedAt: date,
            messages: [
              ChatMessage(
                id: 'message-1',
                role: 'assistant',
                text: 'A partial answer',
                reasoning: 'A partial reasoning trace',
                status: ChatMessageStatus.streaming,
                provider: CloudProvider.zai,
                model: 'glm-test',
                createdAt: date,
              ),
            ],
          ),
        ],
      );

      await store().save(archive);
      final restored = await store().load();

      expect(restored.toJson(), archive.toJson());
      expect(
        restored.threads.single.messages.single.status,
        ChatMessageStatus.streaming,
      );
      expect(restored.threads.single.draft, 'Unsent continuation');
      expect(restored.newChatDraft, 'Unsent new-chat message');
      expect(restored.newChatSystemPrompt, 'New-chat instructions');
      final raw = jsonDecode(await history().readAsString()) as Map;
      expect(raw['schema_version'], 1);
      expect(raw.containsKey('api_key'), isFalse);
      expect(raw.containsKey('keys'), isFalse);
    },
  );

  test(
    'simultaneous saves retain invocation order and snapshot queued data',
    () async {
      final firstReplaceStarted = Completer<void>();
      final releaseFirstReplace = Completer<void>();
      var replacements = 0;
      final persistence = store(
        replaceFile: (temporary, destination) async {
          replacements++;
          if (replacements == 1) {
            firstReplaceStarted.complete();
            await releaseFirstReplace.future;
          }
          await temporary.rename(destination.path);
        },
      );
      final first = persistence.save(
        ChatArchive.empty().copyWith(newChatDraft: 'First'),
      );
      await firstReplaceStarted.future;
      final queuedData = ChatArchive.empty()
          .copyWith(newChatDraft: 'Queued')
          .toJson();
      final second = persistence.save(_MutableArchive(queuedData));
      queuedData['new_chat_draft'] = 'Mutated after save invocation';
      final readAfterQueuedSaves = persistence.load();
      releaseFirstReplace.complete();
      await Future.wait([first, second]);

      expect(replacements, 2);
      expect((await readAfterQueuedSaves).newChatDraft, 'Queued');
      expect((await store().load()).newChatDraft, 'Queued');
      expect(
        await history().parent
            .list()
            .where((entity) => entity.path.endsWith('.tmp'))
            .toList(),
        isEmpty,
      );
    },
  );

  test(
    'failed atomic replace retains valid file and permits a retry',
    () async {
      await store().save(
        ChatArchive.empty().copyWith(newChatDraft: 'Original'),
      );
      final originalBytes = await history().readAsBytes();
      var failReplace = true;
      final persistence = store(
        replaceFile: (temporary, destination) async {
          if (failReplace) {
            throw const FileSystemException(
              'secret-native-detail',
              '/private/path',
            );
          }
          await temporary.rename(destination.path);
        },
      );
      await persistence.load();
      await expectLater(
        persistence.save(ChatArchive.empty().copyWith(newChatDraft: 'New')),
        throwsA(
          isA<ChatStorageException>().having(
            (error) => error.toString(),
            'redacted message',
            isNot(contains('secret-native-detail')),
          ),
        ),
      );
      expect(await history().readAsBytes(), originalBytes);
      expect((await persistence.load()).newChatDraft, 'Original');
      expect(persistence.writesBlocked, isFalse);
      expect(
        await history().parent
            .list()
            .where((entity) => entity.path.endsWith('.tmp'))
            .toList(),
        isEmpty,
      );

      failReplace = false;
      await persistence.save(
        ChatArchive.empty().copyWith(newChatDraft: 'Retry'),
      );
      expect((await store().load()).newChatDraft, 'Retry');
    },
  );

  test('one failed queued write does not reject later queued writes', () async {
    var calls = 0;
    final persistence = store(
      replaceFile: (temporary, destination) async {
        if (++calls == 1) throw const FileSystemException('temporary failure');
        await temporary.rename(destination.path);
      },
    );
    final first = persistence.save(
      ChatArchive.empty().copyWith(newChatDraft: 'Fail'),
    );
    final firstFailure = expectLater(
      first,
      throwsA(isA<ChatStorageException>()),
    );
    final second = persistence.save(
      ChatArchive.empty().copyWith(newChatDraft: 'Succeed'),
    );
    await firstFailure;
    await second;

    expect(calls, 2);
    expect((await store().load()).newChatDraft, 'Succeed');
    expect(persistence.writesBlocked, isFalse);
  });

  for (final corruption in [
    '{malformed private message',
    '[]',
    'unsupported-schema',
  ]) {
    test(
      '$corruption blocks overwrites and preserves existing bytes',
      () async {
        await history().parent.create(recursive: true);
        final data = corruption == 'unsupported-schema'
            ? jsonEncode({
                ...ChatArchive.empty().toJson(),
                'schema_version': 999,
              })
            : corruption;
        await history().writeAsString(data, flush: true);
        final persistence = store();

        await expectLater(
          persistence.load(),
          throwsA(isA<ChatStorageException>()),
        );
        expect(persistence.writesBlocked, isTrue);
        await expectLater(
          persistence.save(ChatArchive.empty()),
          throwsA(isA<ChatStorageException>()),
        );
        expect(await history().readAsString(), data);
      },
    );
  }

  test('save without load cannot overwrite unreadable history', () async {
    await history().parent.create(recursive: true);
    const damaged = '{private unreadable data';
    await history().writeAsString(damaged, flush: true);
    final persistence = store();

    await expectLater(
      persistence.save(ChatArchive.empty()),
      throwsA(
        isA<ChatStorageException>().having(
          (error) => error.toString(),
          'redacted message',
          isNot(contains('private unreadable data')),
        ),
      ),
    );
    expect(persistence.writesBlocked, isTrue);
    expect(await history().readAsString(), damaged);
  });

  test(
    'missing history starts empty and creates private subdirectory on save',
    () async {
      final persistence = store();
      final empty = await persistence.load();
      expect(empty.toJson(), ChatArchive.empty().toJson());
      expect(persistence.writesBlocked, isFalse);
      expect(await history().exists(), isFalse);
      expect(await history().parent.exists(), isFalse);

      await persistence.save(empty.copyWith(newChatDraft: 'Saved'));
      expect(await history().exists(), isTrue);
      expect((await store().load()).newChatDraft, 'Saved');
    },
  );

  test(
    'directory in place of history is unreadable rather than empty',
    () async {
      await Directory(history().path).create(recursive: true);
      final persistence = store();
      await expectLater(
        persistence.load(),
        throwsA(isA<ChatStorageException>()),
      );
      expect(persistence.writesBlocked, isTrue);
      await expectLater(
        persistence.save(ChatArchive.empty()),
        throwsA(isA<ChatStorageException>()),
      );
      expect(await Directory(history().path).exists(), isTrue);
    },
  );
}
