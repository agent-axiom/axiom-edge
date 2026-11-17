import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'chat_models.dart';

abstract class ChatPersistence {
  Future<ChatArchive> load();
  Future<void> save(ChatArchive archive);
}

/// An error safe to display without exposing file content or platform details.
class ChatStorageException implements Exception {
  const ChatStorageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Private application storage with ordered, atomic history replacements.
///
/// The existing archive is checked before the first save, including when callers
/// have not explicitly called load. An unreadable archive blocks writes for this
/// instance so starting the app cannot silently overwrite damaged history.
class ChatStore implements ChatPersistence {
  ChatStore({
    Future<Directory> Function()? directory,
    Future<void> Function(File temporary, File destination)? replaceFile,
  }) : _directory = directory ?? getApplicationSupportDirectory,
       _replaceFile = replaceFile ?? _rename;

  final Future<Directory> Function() _directory;
  final Future<void> Function(File temporary, File destination) _replaceFile;
  final Random _random = Random.secure();
  Future<void> _writeTail = Future<void>.value();
  Future<void>? _initialLoad;
  File? _file;
  ChatArchive? _archive;
  bool _blocked = false;

  static const _readError = ChatStorageException(
    'Не удалось прочитать историю чата. Запись заблокирована, '
    'чтобы сохранить существующие данные.',
  );
  static const _writeError = ChatStorageException(
    'Не удалось сохранить историю чата. Повторите попытку.',
  );

  static Future<void> _rename(File temporary, File destination) async {
    await temporary.rename(destination.path);
  }

  /// Once true, only a new instance may attempt to read the archive again.
  bool get writesBlocked => _blocked;

  @override
  Future<ChatArchive> load() async {
    // Reads invoked after saves observe those saves, including queued ones.
    await _writeTail;
    await _ensureLoaded();
    return _archive!;
  }

  Future<void> _ensureLoaded() async {
    _initialLoad ??= _readArchive();
    await _initialLoad;
    if (_blocked) throw _readError;
  }

  Future<void> _readArchive() async {
    try {
      final root = await _directory();
      final file = File(p.join(root.path, 'chat', 'history.json'));
      _file = file;
      final type = await FileSystemEntity.type(file.path);
      if (type == FileSystemEntityType.notFound) {
        _archive = ChatArchive.empty();
        return;
      }
      if (type != FileSystemEntityType.file) throw const FormatException();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      _archive = ChatArchive.fromJson(decoded);
    } catch (_) {
      _blocked = true;
      throw _readError;
    }
  }

  @override
  Future<void> save(ChatArchive archive) {
    // Capture a detached snapshot now, before this operation enters the queue.
    // Even mutable collections inside a caller's object cannot alter queued IO.
    late final String snapshot;
    late final ChatArchive detached;
    try {
      snapshot = jsonEncode(archive.toJson());
      detached = ChatArchive.fromJson(
        jsonDecode(snapshot) as Map<String, dynamic>,
      );
    } catch (_) {
      return Future<void>.error(_writeError);
    }

    final operation = _writeTail.then((_) async {
      await _ensureLoaded();
      final file = _file!;
      File? temporary;
      try {
        await file.parent.create(recursive: true);
        final nonce = List.generate(
          12,
          (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        temporary = File('${file.path}.$pid.$nonce.tmp');
        await temporary.writeAsString(snapshot, flush: true);
        await _replaceFile(temporary, file);
        _archive = detached;
      } catch (_) {
        // A transient write failure must not poison subsequent queued writes.
        throw _writeError;
      } finally {
        if (temporary != null) {
          try {
            if (await temporary.exists()) await temporary.delete();
          } catch (_) {
            // Cleanup failure must not leak native details or hide IO status.
          }
        }
      }
    });
    // Consume errors only for the queue tail. The caller still receives the
    // original operation and therefore observes every failed save.
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }
}

abstract class ChatKeyVault {
  Future<String?> read(CloudProvider provider);
  Future<void> write(CloudProvider provider, String key);
  Future<void> delete(CloudProvider provider);
}

class ChatKeyStorageException implements Exception {
  const ChatKeyStorageException();

  @override
  String toString() =>
      'Не удалось открыть защищённое хранилище ключей. Повторите попытку.';
}

/// Keys live only in the platform's secure storage, never in chat history.
class SecureChatKeyVault implements ChatKeyVault {
  SecureChatKeyVault({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              storageNamespace: 'axiom_edge_cloud',
              resetOnError: false,
            ),
            iOptions: IOSOptions(
              accountName: 'axiom_edge_cloud',
              accessibility: KeychainAccessibility.unlocked_this_device,
              synchronizable: false,
            ),
          );

  final FlutterSecureStorage _storage;

  static String _key(CloudProvider provider) => switch (provider) {
    CloudProvider.openai => 'axiom_edge_byok_openai',
    CloudProvider.zai => 'axiom_edge_byok_zai',
  };

  @override
  Future<String?> read(CloudProvider provider) async {
    try {
      return await _storage.read(key: _key(provider));
    } catch (_) {
      throw const ChatKeyStorageException();
    }
  }

  @override
  Future<void> write(CloudProvider provider, String key) async {
    try {
      await _storage.write(key: _key(provider), value: key);
    } catch (_) {
      throw const ChatKeyStorageException();
    }
  }

  @override
  Future<void> delete(CloudProvider provider) async {
    try {
      await _storage.delete(key: _key(provider));
    } catch (_) {
      throw const ChatKeyStorageException();
    }
  }
}
