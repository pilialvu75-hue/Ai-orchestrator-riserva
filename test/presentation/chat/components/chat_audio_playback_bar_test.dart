import 'package:ai_orchestrator/presentation/chat/components/chat_audio_playback_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('audio transport allows real stop, restart and dismissal',
      (tester) async {
    var stops = 0;
    var restarts = 0;
    var closes = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          child: ChatAudioPlaybackBar(
            isPlaying: true,
            isBusy: false,
            onStop: () => stops++,
            onRestart: () => restarts++,
            onClose: () => closes++,
          ),
        ),
      ),
    ));
    expect(find.text('Ascolto'), findsOneWidget);
    await tester.tap(find.byTooltip('Ricomincia dall’inizio'));
    await tester.tap(find.byTooltip('Interrompi lettura'));
    await tester.tap(find.byTooltip('Chiudi lettore'));
    expect(restarts, 1);
    expect(stops, 1);
    expect(closes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stopped and busy states disable unsupported actions',
      (tester) async {
    var closes = 0;
    Widget app(bool playing, bool busy) => MaterialApp(
      home: Scaffold(
        body: ChatAudioPlaybackBar(
          isPlaying: playing,
          isBusy: busy,
          onStop: () => fail('Must not stop inactive audio'),
          onRestart: () => fail('Must not restart while busy'),
          onClose: () => closes++,
        ),
      ),
    );

    await tester.pumpWidget(app(false, false));
    expect(find.text('Fermo'), findsOneWidget);
    expect(find.byTooltip('Interrompi lettura'), findsNothing);

    await tester.pumpWidget(app(false, true));
    expect(find.text('Audio…'), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);
    final restartButton = tester.widget<IconButton>(
      find.byWidgetPredicate((widget) =>
          widget is IconButton && widget.tooltip == 'Ricomincia dall’inizio'),
    );
    expect(restartButton.onPressed, isNull);
    await tester.tap(find.byTooltip('Chiudi lettore'));
    expect(closes, 1);
  });
}
