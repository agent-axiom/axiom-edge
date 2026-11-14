import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'registry.dart';

typedef DownloadProgress = void Function(double? ratio, String detail);

class ModelDownloadService {
  ModelDownloadService(this.registry);
  final ModelRegistry registry;

  static const ggufFile = 'MNN-Pocket-0.3B-Instruct-Q4_1.gguf';
  static const ggufRepo = 'taobao-mnn/MNN-Pocket-0.3B-GGUF';
  static const mnnRepo = 'taobao-mnn/MNN-Pocket-0.3B-MNN';
  static const mnnFiles = [
    'config.json',
    'llm_config.json',
    'llm.mnn',
    'llm.mnn.weight',
    'tokenizer.mtok',
  ];

  static Uri hfFile(String repo, String filename) =>
      Uri.parse('https://huggingface.co/$repo/resolve/main/$filename');

  Future<LocalModel> downloadGguf(DownloadProgress progress) async {
    final base = await registry.root;
    final dir = Directory(p.join(base.path, 'files'))
      ..createSync(recursive: true);
    final target = File(p.join(dir.path, ggufFile));
    if (!await target.exists() || await target.length() < 100000000) {
      await _download(hfFile(ggufRepo, ggufFile), target, progress);
    }
    if (await target.length() < 100000000) {
      await target.delete();
      throw const FormatException('Incomplete Pocket GGUF model');
    }
    final magic = await target
        .openRead(0, 4)
        .fold<List<int>>(<int>[], (out, bytes) => out..addAll(bytes));
    if (String.fromCharCodes(magic) != 'GGUF') {
      throw const FormatException('Invalid GGUF header');
    }
    progress(1, 'Проверяем SHA-256');
    final hash = await sha256.bind(target.openRead()).first;
    final model = LocalModel(
      id: 'pocket-0.3b-q4_1',
      name: 'MNN-Pocket-0.3B · GGUF Q4_1',
      format: ModelFormat.gguf,
      location: target.path,
      source: '$ggufRepo/$ggufFile',
      sha256: hash.toString(),
    );
    await registry.upsert(model);
    return model;
  }

  /// MNN is Android-only until a tested iOS runtime adapter is available.
  /// Downloading files does not itself register the model with mnn_engine.
  Future<Directory> downloadMnn(DownloadProgress progress) async {
    final root = await registry.root;
    final dir = Directory(p.join(root.path, 'mnn-staging', 'pocket-0.3b'));
    await dir.create(recursive: true);
    for (var index = 0; index < mnnFiles.length; index++) {
      final name = mnnFiles[index];
      final target = File(p.join(dir.path, name));
      final minimum = name == 'llm.mnn.weight'
          ? 100000000
          : (name == 'tokenizer.mtok' ? 1000000 : 1);
      if (!await target.exists() || await target.length() < minimum) {
        await _download(hfFile(mnnRepo, name), target, (fraction, detail) {
          progress(
            fraction == null ? null : (index + fraction) / mnnFiles.length,
            '$name: $detail',
          );
        });
      }
      if (await target.length() < minimum) {
        await target.delete();
        throw FormatException('Incomplete MNN file: $name');
      }
      progress((index + 1) / mnnFiles.length, '$name готов');
    }
    return dir;
  }

  Future<void> _download(
    Uri url,
    File target,
    DownloadProgress progress,
  ) async {
    final temp = File('${target.path}.part');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.userAgentHeader, 'axiom-edge/0.1.2');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Download failed: HTTP ${response.statusCode}',
          uri: url,
        );
      }
      if (await temp.exists()) await temp.delete();
      final output = temp.openWrite();
      var bytes = 0;
      final expected = response.contentLength;
      try {
        await for (final chunk in response) {
          output.add(chunk);
          bytes += chunk.length;
          progress(
            expected > 0 ? bytes / expected : null,
            '${(bytes / 1048576).toStringAsFixed(1)} MiB',
          );
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (bytes == 0 || (expected >= 0 && bytes != expected)) {
        throw StateError('Truncated download: $bytes/$expected bytes');
      }
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}
