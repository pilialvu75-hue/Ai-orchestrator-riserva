import 'package:ai_orchestrator/presentation/chat/components/chat_audio_playback_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('real controls pause resume and seek instead of stop/restart',
      (tester) async {
    var pauses = 0;
    var resumes = 0;
    var backs = 0;
    var forwards = 0;
    var closes = 0;
    Duration? sought;
    Widget player({bool paused = false}) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: ChatAudioPlaybackBar(
                isPlaying: !paused,
                isBusy: false,
                realTransport: true,
                isPaused: paused,
                position: const Duration(seconds: 12),
                buffered: const Duration(seconds: 40),
                complete: false,
                onStop: () => fail('Do not stop when pausing'),
                onRestart: () => fail('Do not regenerate when resuming'),
                onPause: () => pauses++,
                onResume: () => resumes++,
                onBack: () => backs++,
                onForward: () => forwards++,
                onSeek: (position) => sought = position,
                onClose: () => closes++,
              ),
            ),
          ),
        );

    await tester.pumpWidget(player());
    expect(find.text('0:12 / 0:40 · generato'), findsOneWidget);
    await tester.tap(find.byTooltip('Pausa lettura'));
    await tester.tap(find.byTooltip('Indietro 10 secondi'));
    await tester.tap(find.byTooltip('Avanti 10 secondi'));
    expect(pauses, 1);
    expect(backs, 1);
    expect(forwards, 1);

    final slider = find.byType(Slider);
    await tester.drag(slider, const Offset(20, 0));
    await tester.pumpAndSettle();
    expect(sought, isNotNull);
    expect(sought!.inMilliseconds, greaterThan(12000));

    await tester.pumpWidget(player(paused: true));
    await tester.tap(find.byTooltip('Riprendi lettura'));
    await tester.tap(find.byTooltip('Chiudi lettore'));
    expect(resumes, 1);
    expect(closes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finished service offers explicit replay, not stale resume',
      (tester) async {
    var restarts = 0;
    var resumes = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          child: ChatAudioPlaybackBar(
            isPlaying: false,
            isBusy: false,
            realTransport: true,
            position: const Duration(seconds: 90),
            buffered: const Duration(seconds: 90),
            complete: true,
            onStop: () => fail('No stop after finished audio'),
            onRestart: () => restarts++,
            onResume: () => resumes++,
            onClose: () {},
          ),
        ),
      ),
    ));
    expect(find.byTooltip('Riascolta dall’inizio'), findsOneWidget);
    await tester.tap(find.byTooltip('Riascolta dall’inizio'));
    expect(restarts, 1);
    expect(resumes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('seek is disabled until real PCM exists', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: ChatAudioPlaybackBar(
            isPlaying: false,
            isBusy: true,
            realTransport: true,
            onStop: () {},
            onRestart: () {},
            onClose: () {},
          ),
        ),
      ),
    ));
    expect(find.byTooltip('Preparazione audio'), findsOneWidget);
    final back = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'Indietro 10 secondi'));
    final forward = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'Avanti 10 secondi'));
    expect(back.onPressed, isNull);
    expect(forward.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
