import 'package:ai_orchestrator/features/chat/presentation/widgets/empty_trash_confirmation_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('confirm dialog names the number of permanently deleted chats',
      (tester) async {
    bool? accepted;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) => TextButton(
          onPressed: () async {
            accepted = await showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) => const EmptyTrashConfirmationDialog(chatCount: 3),
            );
          },
          child: const Text('Apri cestino'),
        )),
      ),
    ));

    await tester.tap(find.text('Apri cestino'));
    await tester.pumpAndSettle();
    expect(find.text('Svuotare il cestino?'), findsOneWidget);
    expect(find.textContaining('3 conversazioni'), findsOneWidget);
    expect(find.textContaining('Non sarà possibile ripristinarle'), findsOneWidget);
    expect(find.text('Annulla'), findsOneWidget);
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    expect(accepted, false);

    await tester.tap(find.text('Apri cestino'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elimina definitivamente'));
    await tester.pumpAndSettle();
    expect(accepted, true);
  });

  testWidgets('singular count and preserved personal memories disclosed',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: EmptyTrashConfirmationDialog(chatCount: 1)),
    ));
    expect(find.textContaining('1 conversazione'), findsOneWidget);
    expect(find.textContaining('ricordi personali'), findsOneWidget);
  });
}
