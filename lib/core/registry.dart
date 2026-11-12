import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

class ModelRegistry {
  Future<Directory> get root async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'axiom-edge'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<List<LocalModel>> read() async {
    final dir = await root;
    final file = File(p.join(dir.path, 'models.json'));
    if (!await file.exists()) return [];
    final parsed = jsonDecode(await file.readAsString());
    if (parsed is! List) throw const FormatException('Invalid model registry');
    return [
      for (final row in parsed)
        LocalModel.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  Future<void> upsert(LocalModel model) async {
    final models = await read();
    models.removeWhere((m) => m.id == model.id);
    models.add(model);
    await save(models);
  }

  Future<void> save(List<LocalModel> models) async {
    final dir = await root;
    final target = File(p.join(dir.path, 'models.json'));
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(models.map((m) => m.toJson()).toList()),
      flush: true,
    );
    // Atomic replace on the Android/iOS POSIX filesystems.
    await temporary.rename(target.path);
  }
}
