import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mnn_engine/mnn_engine.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../engines/gguf_runner.dart';
import '../engines/mnn_runner.dart';
import 'download.dart';
import 'models.dart';
import 'registry.dart';
import 'runner.dart';

class LabState extends ChangeNotifier {
  final ModelRegistry registry = ModelRegistry();
  late final ModelDownloadService downloads = ModelDownloadService(registry);

  List<LocalModel> models = [];
  LocalModel? active;
  ModelRunner? _runner;
  List<ChatTurn> chat = [];
  InferenceMetrics? lastMetrics;
  List<EvalResult> evals = [];
  String suiteName = 'pocket-smoke-v1';
  String status = 'Готов';
  String device = 'Неизвестное устройство';
  String? error;
  double? progress;
  bool busy = false;
  bool generating = false;
  bool _disposed = false;
  bool _cancelRequested = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  bool get isAndroid => Platform.isAndroid;
  bool get isReady => active != null && _runner != null;

  Future<void> init() async {
    try {
      models = await registry.read();
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        device =
            '${info.manufacturer} ${info.model} · Android ${info.version.release}';
      } else if (Platform.isIOS) {
        final info = await DeviceInfoPlugin().iosInfo;
        device = '${info.utsname.machine} · iOS ${info.systemVersion}';
      }
    } catch (e) {
      error = 'Инициализация: $e';
    }
    notifyListeners();
  }

  Future<void> _guarded(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    error = null;
    progress = null;
    _cancelRequested = false;
    notifyListeners();
    try {
      await action();
    } catch (e) {
      error = e.toString();
      status = 'Ошибка';
    } finally {
      busy = false;
      progress = null;
      notifyListeners();
    }
  }

  Future<void> downloadGguf() => _guarded(() async {
    status = 'Скачиваем GGUF';
    final model = await downloads.downloadGguf((fraction, detail) {
      progress = fraction;
      status = 'GGUF: $detail';
      notifyListeners();
    });
    models = await registry.read();
    status = '${model.name} сохранена';
  });

  Future<void> downloadMnn() => _guarded(() async {
    if (!isAndroid) throw UnsupportedError('MNN доступен только на Android');
    status = 'Скачиваем MNN';
    final staging = await downloads.downloadMnn((fraction, detail) {
      progress = fraction;
      status = 'MNN: $detail';
      notifyListeners();
    });
    status = 'Регистрируем MNN';
    notifyListeners();
    final info = await MnnEngine.instance.initialize();
    if (!info.nativeLibraryLoaded) {
      throw StateError('MNN native library not loaded');
    }
    final imported = await MnnEngine.instance.importModelFromPath(staging.path);
    final model = LocalModel(
      id: 'mnn-${imported.modelId}',
      name: 'MNN-Pocket-0.3B · MNN INT4',
      format: ModelFormat.mnn,
      location: imported.modelId,
      source: ModelDownloadService.mnnRepo,
    );
    await registry.upsert(model);
    models = await registry.read();
    await staging.delete(recursive: true);
    status = '${model.name} сохранена';
  });

  Future<void> importGguf() => _guarded(() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['gguf'],
    );
    if (picked == null) return;
    final filePath = picked.path;
    if (filePath == null) {
      throw StateError('Система не предоставила путь к файлу');
    }
    final source = File(filePath);
    if (!await source.exists()) {
      throw StateError('Не удаётся прочитать выбранный файл');
    }
    if (await source.length() < 1024) {
      throw StateError('Файл слишком мал для GGUF');
    }
    final magic = await source
        .openRead(0, 4)
        .fold<List<int>>(<int>[], (out, b) => out..addAll(b));
    if (String.fromCharCodes(magic) != 'GGUF') {
      throw const FormatException('Неверный формат GGUF');
    }
    final root = await registry.root;
    final dir = Directory(p.join(root.path, 'imported'));
    await dir.create(recursive: true);
    final id = 'gguf-${DateTime.now().microsecondsSinceEpoch}';
    final destination = File(p.join(dir.path, '$id.gguf'));
    status = 'Импортируем ${picked.name}';
    notifyListeners();
    await source.copy(destination.path);
    final model = LocalModel(
      id: id,
      name: picked.name,
      format: ModelFormat.gguf,
      location: destination.path,
      source: 'local-import',
    );
    await registry.upsert(model);
    models = await registry.read();
    status = 'Импорт завершён';
  });

  Future<void> importMnn() => _guarded(() async {
    if (!isAndroid) throw UnsupportedError('MNN доступен только на Android');
    status = 'Выбери папку MNN';
    final engine = MnnEngine.instance;
    await engine.initialize();
    final imported = await engine.importModelDirectory();
    final model = LocalModel(
      id: 'mnn-${imported.modelId}',
      name: imported.modelId,
      format: ModelFormat.mnn,
      location: imported.modelId,
      source: 'local-import',
    );
    await registry.upsert(model);
    models = await registry.read();
    status = 'Импорт завершён';
  });

  Future<void> selectModel(LocalModel model) => _guarded(() async {
    status = 'Загружаем ${model.name}';
    notifyListeners();
    await _runner?.dispose();
    _runner = null;
    active = null;
    chat = [];
    evals = [];
    lastMetrics = null;
    final runner = model.format == ModelFormat.gguf
        ? GgufRunner()
        : MnnRunner();
    try {
      await runner.load(model);
      _runner = runner;
      active = model;
      status = 'Модель загружена';
    } catch (_) {
      await runner.dispose();
      rethrow;
    }
  });

  Future<void> send(String input) => _guarded(() async {
    final runner = _runner;
    if (runner == null) throw StateError('Сначала загрузи модель');
    final text = input.trim();
    if (text.isEmpty) return;
    chat.add(ChatTurn('user', text));
    chat.add(const ChatTurn('assistant', ''));
    status = 'Генерация';
    generating = true;
    notifyListeners();
    final answerIndex = chat.length - 1;
    final history = chat.sublist(0, answerIndex);
    try {
      final result = await runner.generate(
        history,
        onDelta: (chunk) {
          chat[answerIndex] = ChatTurn(
            'assistant',
            chat[answerIndex].text + chunk,
          );
          notifyListeners();
        },
      );
      chat[answerIndex] = ChatTurn('assistant', result.text);
      lastMetrics = result.metrics;
      status = 'Ответ готов';
    } finally {
      generating = false;
    }
  });

  Future<void> runSmoke() => _guarded(() async {
    final runner = _runner;
    if (runner == null) throw StateError('Сначала загрузи модель');
    evals = [];
    generating = true;
    final jsonText = await rootBundle.loadString('assets/evals/smoke.json');
    final spec = jsonDecode(jsonText) as Map<String, dynamic>;
    suiteName = spec['suite'] as String;
    final cases = (spec['cases'] as List)
        .map((x) => EvalCase.fromJson(Map<String, dynamic>.from(x as Map)))
        .toList();
    try {
      for (var i = 0; i < cases.length; i++) {
        if (_cancelRequested) break;
        final test = cases[i];
        progress = i / cases.length;
        status = 'Проверка ${i + 1}/${cases.length}: ${test.id}';
        notifyListeners();
        final response = await runner.generate(
          [ChatTurn('user', test.prompt)],
          maxTokens: 96,
          temperature: 0.1,
        );
        evals.add(
          EvalResult(
            caseId: test.id,
            passed: evaluate(test, response.text),
            response: response.text,
            metrics: response.metrics,
          ),
        );
        lastMetrics = response.metrics;
        notifyListeners();
      }
      progress = 1;
      status = _cancelRequested ? 'Проверки остановлены' : 'Проверки завершены';
    } finally {
      generating = false;
    }
  });

  void cancel() {
    _cancelRequested = true;
    _runner?.cancel();
    status = 'Остановка запрошена';
    notifyListeners();
  }

  Future<void> exportResults({Rect? sharePositionOrigin}) async {
    final model = active;
    if (model == null || evals.isEmpty) return;
    final payload = {
      'schema_version': '1.0',
      'app_version': '0.1.1',
      'date': DateTime.now().toUtc().toIso8601String(),
      'device': device,
      'model': model.toJson(),
      'engine': model.format == ModelFormat.gguf ? 'llama.cpp' : 'MNN',
      'suite': suiteName,
      'summary': {
        'passed': evals.where((x) => x.passed).length,
        'total': evals.length,
      },
      'cases': evals.map((x) => x.toJson()).toList(),
    };
    final temp = await getTemporaryDirectory();
    final file = File(
      p.join(
        temp.path,
        'axiom-edge-${DateTime.now().millisecondsSinceEpoch}.json',
      ),
    );
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        text: 'Axiom Edge benchmark',
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_runner?.dispose());
    super.dispose();
  }
}
