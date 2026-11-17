import 'package:axiom_edge/chat/chat_models.dart';
import 'package:axiom_edge/chat/chat_state.dart';
import 'package:axiom_edge/chat/chat_store.dart';
import 'package:axiom_edge/core/lab_state.dart';
import 'package:axiom_edge/core/models.dart';
import 'package:axiom_edge/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryHistory implements ChatPersistence {
  ChatArchive archive = ChatArchive.empty();
  @override
  Future<ChatArchive> load() async => archive;
  @override
  Future<void> save(ChatArchive value) async => archive = value;
}

class _NoKeys implements ChatKeyVault {
  @override
  Future<String?> read(CloudProvider provider) async => null;
  @override
  Future<void> write(CloudProvider provider, String key) async {}
  @override
  Future<void> delete(CloudProvider provider) async {}
}

class _NoNetwork implements CloudGateway {
  @override
  Future<List<String>> listModels(CloudProvider provider, String apiKey) =>
      throw StateError('No request expected');
  @override
  Stream<CloudChunk> stream({
    required CloudProvider provider,
    required String apiKey,
    required String model,
    required List<ChatTurn> messages,
    String systemPrompt = '',
  }) => throw StateError('No request expected');
  @override
  void cancel() {}
  @override
  void close() {}
}

void main() {
  testWidgets('app starts in cloud chat without downloading a local model', (
    tester,
  ) async {
    final chats = ChatState(
      store: _MemoryHistory(),
      keyVault: _NoKeys(),
      gateway: _NoNetwork(),
    );
    await chats.init();
    final lab = LabState();
    await tester.pumpWidget(AxiomEdgeApp(state: lab, chats: chats));
    await tester.pumpAndSettle();
    expect(find.text('С чего начнём?'), findsOneWidget);
    expect(find.text('Движок не загружен'), findsNothing);
    expect(lab.active, isNull);

    await tester.tap(find.text('Локальные'));
    await tester.pumpAndSettle();
    expect(find.text('Найти и загрузить'), findsOneWidget);
    expect(find.text('Движок не загружен'), findsOneWidget);

    await tester.tap(find.text('Проверки'));
    await tester.pumpAndSettle();
    expect(find.text('Замер скорости'), findsOneWidget);

    await tester.tap(find.text('Чаты'));
    await tester.pumpAndSettle();
    expect(find.text('С чего начнём?'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
