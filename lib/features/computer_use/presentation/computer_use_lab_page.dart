import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;
import 'package:ai_orchestrator/core/ai/entities/ai_model.dart';
import 'package:ai_orchestrator/core/ai/providers/local_ai_repository.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_provider.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_2048_benchmark.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_2048_experience.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_2048_local_agent.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_agent_runner.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_aivexus_local_decision_model.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_build_policy.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_game_catalog.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_preview_policy.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_smoke_scenario.dart';
import 'package:ai_orchestrator/features/computer_use/android_computer_use_adapter.dart';
import 'package:ai_orchestrator/features/computer_use/mac_computer_use_adapter.dart';
import 'package:ai_orchestrator/features/computer_use/windows_computer_use_adapter.dart';
import 'package:ai_orchestrator/features/computer_use/windows_computer_use_accessibility_reader.dart';

/// Manual, local proof-of-life UI. No LLM is authorized to start a session.
/// A later agent loop can reuse ComputerUseSession after physical host QA.
class ComputerUseLabPage extends StatefulWidget {
  const ComputerUseLabPage({super.key});

  @override
  State<ComputerUseLabPage> createState() => _ComputerUseLabPageState();
}

ComputerUseAdapter _labAdapter() {
  if (!kIsWeb) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidComputerUseAdapter();
      case TargetPlatform.macOS:
        return MacComputerUseAdapter();
      case TargetPlatform.windows:
        return WindowsComputerUseAdapter();
      default:
        break;
    }
  }
  return WindowsComputerUseAdapter();
}

class _ComputerUseLabPageState extends State<ComputerUseLabPage> {
  static const MethodChannel _screenVision =
      MethodChannel('com.aiorchestrator/screen_vision');
  static const MethodChannel _androidGestures =
      MethodChannel('com.aiorchestrator/computer_use_android');
  static const MethodChannel _macScreen =
      MethodChannel('com.aiorchestrator/computer_use_mac');
  late final ComputerUseAdapter _adapter = _labAdapter();
  late final ComputerUseSession _session =
      ComputerUseSession(adapter: _adapter);
  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _isMac =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  bool get _canInput =>
      _adapter is! ComputerUseInteractionCapability ||
      (_adapter as ComputerUseInteractionCapability).supportsInteraction;
  bool _projectionStartedByLab = false;
  Timer? _expiryTimer;
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _appSearchController = TextEditingController();

  Uint8List? _frame;
  int _frameWidth = 1;
  int _frameHeight = 1;
  bool _busy = false;
  bool _selectTargetOnNextTap = false;
  ComputerUse2048Benchmark? _previousGameScore;
  ComputerUseAgentRunner? _gameRunner;
  String _message = 'Nessuna sessione attiva.';

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _gameRunner?.stop();
    _session.stop();
    if (_isAndroid) {
      unawaited(_androidGestures.invokeMethod<void>('clearTarget'));
    }
    unawaited(_releaseProjection());
    _textController.dispose();
    _appSearchController.dispose();
    super.dispose();
  }

  Future<void> _releaseProjection() async {
    if (!_projectionStartedByLab) return;
    _projectionStartedByLab = false;
    try {
      await _screenVision.invokeMethod<void>('stopProjection');
    } catch (_) {
      // The existing ScreenVision service may already be gone.
    }
  }

  Future<void> _openCarJamPlayStore() async {
    if (!_isAndroid || !ComputerUseLabBuildPolicy.enabled) return;
    // This is a trusted user's explicit tap, NEVER a model tool action.
    // The Play Store owns all subsequent prompts, login and installation.
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Car Jam Solver — gioco di terzi'),
        content: const Text(
          'Vuoi aprire la scheda ufficiale Ladaneta Games su Google Play? '
          'Il gioco contiene pubblicità e acquisti in-app. '
          'Aivexus NON installerà nulla automaticamente, '
          'non effettuerà acquisti e non userà il tuo account Google.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Apri Play Store'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    await _run(() async {
      final opened = await launchUrl(
        ComputerUseGameCatalog.carJamPlayStoreUri,
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        throw const ComputerUseException(
          'PLAY_STORE_UNAVAILABLE',
          'Non posso aprire Google Play su questo dispositivo.',
        );
      }
      if (mounted) {
        setState(() => _message =
            'Scheda Play Store aperta. Installazione sotto il tuo '
            'controllo. Computer Use Android resta in sola osservazione.');
      }
    });
  }

  Future<void> _typeAndroidSelectedText() async {
    if (!_isAndroid || !_session.isActive || _busy) return;
    final value = _textController.text;
    if (value.isEmpty || value.length > 512) return;
    final consent = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Inserire testo nell’app selezionata?'),
        content: const Text(
          'AIVEXUS inserirà il testo nel campo modificabile attualmente '
          'selezionato. Torna nell’app entro 4 secondi. Non inserire '
          'password o dati sensibili. Il salvataggio non è automatico.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Autorizza inserimento'),
          ),
        ],
      ),
    );
    if (consent != true || !mounted) return;
    final revision = _session.sessionRevision;
    await _run(() async {
      setState(() => _message = 'Torna nell’app: inserimento fra 4 secondi.');
      await Future<void>.delayed(const Duration(seconds: 4));
      if (!_session.isActive || revision != _session.sessionRevision) return;
      final outcome = await _androidGestures.invokeMethod<String>(
        'typeTargetText', <String, String>{'text': value},
      );
      if (mounted && revision == _session.sessionRevision) {
        setState(() => _message = 'Esito inserimento testo nel campo selezionato: '
            '${outcome ?? 'nessun risultato'}. Conferma il contenuto nell’app prima di considerarlo salvato.');
      }
    });
  }

  Future<void> _findAndOpenAndroidApp() async {
    if (!_isAndroid || _busy) return;
    final query = _appSearchController.text.trim();
    if (query.length < 2) {
      setState(() => _message = 'Scrivi almeno due caratteri dell’app da aprire.');
      return;
    }
    await _run(() async {
      final matches = await _androidGestures.invokeListMethod<dynamic>(
        'findInstalledApps',
        <String, Object>{'query': query},
      );
      if (!mounted) return;
      final apps = (matches ?? const <dynamic>[])
          .whereType<Map>()
          .map((entry) => <String, String>{
                'label': (entry['label'] ?? '').toString(),
                'package': (entry['package'] ?? '').toString(),
              })
          .where((entry) => entry['package']!.isNotEmpty)
          .toList();
      if (apps.isEmpty) {
        setState(() => _message = 'Nessuna app installata trovata per: $query.');
        return;
      }
      final selected = await showDialog<Map<String, String>>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Quale app vuoi aprire?'),
          children: [
            for (final app in apps)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, app),
                child: Text(app['label']!),
              ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      await _androidGestures.invokeMethod<bool>(
        'launchInstalledApp',
        <String, Object>{'package': selected['package']!},
      );
      if (mounted) {
        setState(() => _message =
            'Apertura richiesta: ${selected['label']}. '
            'L’app non è ancora controllata: selezionala con Acquisisci.');
      }
    });
  }

  Future<void> _openAndroidAccessibilitySettings() async {
    if (!_isAndroid) return;
    await _run(() async {
      await _androidGestures.invokeMethod<void>('openAccessibilitySettings');
      if (mounted) {
        setState(() => _message =
            'In Accessibilità abilita AIVEXUS Computer Use solo se '
            'vuoi autorizzare i gesti su un’app selezionata.');
      }
    });
  }

  Offset? _androidPanStart;
  Offset? _androidPanLast;

  Future<void> _tapAndroidGameFrame(TapUpDetails details, double width) async {
    await _sendAndroidGameGesture(
      details.localPosition, details.localPosition, width,
    );
  }

  Future<void> _sendAndroidGameGesture(
    Offset start, Offset end, double width,
  ) async {
    if (!_isAndroid || !_session.isActive || _busy || _frame == null) return;
    int imageX(Offset position) =>
        (position.dx * _frameWidth / width)
            .floor().clamp(0, _frameWidth - 1);
    int imageY(Offset position) =>
        (position.dy * _frameWidth / width)
            .floor().clamp(0, _frameHeight - 1);
    final x = imageX(start);
    final y = imageY(start);
    final endX = imageX(end);
    final endY = imageY(end);
    final swipe = x != endX || y != endY;
    if (swipe && (end - start).distance < 16) return;
    final status =
        await _androidGestures.invokeMapMethod<String, dynamic>('getStatus');
    if (!mounted) return;
    if (status?['accessibilityEnabled'] != true) {
      setState(() => _message =
          'Abilita prima Computer Use nelle Impostazioni di accessibilità.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(swipe ? 'Scorrimento nell’app selezionata'
            : 'Tocco nell’app selezionata'),
        content: Text(
          'Fra 4 secondi AIVEXUS proverà ${swipe ? 'uno scorrimento' : 'un tocco'} '
          'da ($x, $y) a ($endX, $endY). Torna subito nell’app acquisita. '
          'Se nel frattempo cambia la finestra, il gesto sarà bloccato.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Autorizzo questo gesto'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final revision = _session.sessionRevision;
    await _run(() async {
      setState(() => _message =
          'Torna nell’app selezionata: gesto fra 4 secondi. STOP annulla.');
      await Future<void>.delayed(const Duration(seconds: 4));
      if (!_session.isActive || revision != _session.sessionRevision) return;
      final outcome = await _androidGestures.invokeMethod<String>(
        swipe ? 'swipeTarget' : 'tapTarget',
        <String, Object>{'x': x, 'y': y, 'endX': endX, 'endY': endY},
      );
      if (mounted && revision == _session.sessionRevision) {
        setState(() => _message =
            'Gesto Android: ${outcome ?? 'nessun risultato'}. '
            'Verifica il cambiamento nell’app. Per un altro gesto '
            'acquisisci nuovamente la finestra.');
      }
    });
  }

  Future<bool> _requestMacScreenRecording() async {
    final status =
        await _macScreen.invokeMapMethod<String, dynamic>('getStatus');
    if (status?['authorized'] == true) return true;
    final permitted =
        await _macScreen.invokeMethod<bool>('requestScreenRecording');
    // macOS may require app restart after the user grants permission.
    return permitted == true;
  }

  Future<bool> _requestAndroidProjection() async {
    final status =
        await _screenVision.invokeMapMethod<String, dynamic>('getStatus');
    if (status?['active'] == true) return true;
    final granted =
        await _screenVision.invokeMethod<bool>('requestProjection');
    if (granted == true) {
      _projectionStartedByLab = true;
      return true;
    }
    return false;
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        setState(() => _message = error.toString());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _begin({required bool interactive}) async {
    if (!ComputerUseLabBuildPolicy.enabled) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Autorizzare Computer Use?'),
        content: Text(
          interactive
              ? 'Per 10 minuti Aivexus potra acquisire schermate e '
                'inviare clic o tasti sul desktop Windows. '
                'Non inserire password o dati sensibili durante il test.'
              : 'Per 10 minuti Aivexus potra acquisire schermate '
                'localmente, senza inviarle al Cloud.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Autorizza'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      if (_isAndroid && !await _requestAndroidProjection()) {
        if (mounted) {
          setState(() => _message = 'Autorizzazione schermo Android negata.');
        }
        return;
      }
      if (_isMac && !await _requestMacScreenRecording()) {
        if (mounted) {
          setState(() => _message =
              'Consenti Registrazione schermo nelle Impostazioni macOS. '
              'Potrebbe essere necessario riavviare Aivexus.');
        }
        return;
      }
      try {
        _session.beginSession(allowInteraction: interactive);
        _selectTargetOnNextTap = false;
        _previousGameScore = null;
        await _refreshFrame();
        _expiryTimer?.cancel();
        _expiryTimer = Timer(const Duration(minutes: 10), () {
          if (mounted) _stop();
        });
        if (mounted) {
          setState(() => _message = interactive
              ? 'Interazione attiva: tocca una finestra nella schermata.'
              : 'Sola osservazione attiva. Nessun dato inviato al Cloud.');
        }
      } catch (_) {
        _session.stop();
        await _releaseProjection();
        rethrow;
      }
    });
  }

  Future<void> _runAutomaticSmokeTest() async {
    if (!_session.canInteract) return;
    await _run(() async {
      final result = await ComputerUseSmokeScenario().run(
        session: _session,
        onStage: (stage) {
          if (mounted) {
            setState(() => _message = 'Test automatico: $stage');
          }
        },
      );
      if (mounted) {
        setState(() {
          _message = result.passed
              ? 'PASS: Blocco note avviato, testo scritto e verificato '
                  'tramite accessibilita Windows.'
              : 'NON SUPERATO: fase ${result.stage}, '
                  'codice ${result.code}.';
        });
      }
    });
  }

  Future<void> _selectTargetWindow() async {
    await _run(() async {
      if (mounted) {
        setState(() => _message =
            'Passa ora alla finestra da controllare (4 secondi).');
      }
      await Future<void>.delayed(const Duration(seconds: 4));
      if (!_session.canInteract) return;
      final result = await _session.execute(<String, dynamic>{
        'action': 'select_window',
      });
      if (!result.success) {
        throw ComputerUseException(
          result.error ?? 'TARGET_NOT_FOUND',
          result.output,
        );
      }
      if (mounted) {
        setState(() => _message =
            'Finestra selezionata. Torna in Aivexus per inviare i comandi.');
      }
    });
  }

  Future<void> _readWindowsAccessibility() async {
    if (!_isWindows || !_session.isActive ||
        _adapter is! WindowsComputerUseAdapter) return;
    await _run(() async {
      final revision = _session.sessionRevision;
      final windowsAdapter = _adapter;
      final reader = WindowsComputerUseAccessibilityReader(
        session: _session,
        captureAccessibilityJson:
            windowsAdapter.captureSelectedAccessibilityJson,
      );
      final summary = await reader.describe(Uint8List(0));
      if (!_session.isActive ||
          _session.sessionRevision != revision ||
          !mounted) return;
      final game = summary.sensitive
          ? null
          : ComputerUse2048Benchmark.parse(summary.description);
      setState(() {
        if (game != null) {
          final previous = _previousGameScore;
          final gained = previous == null ? 0 : game.score - previous.score;
          _message = '2048 QA (dati osservati, non dichiarati dalla IA): '
              'punteggio ${game.score}, casella massima ${game.bestTile}, '
              'mosse ${game.moves}, stato ${game.state}. '
              '${previous == null ? "Prima rilevazione." : "Differenza punteggio: $gained."}';
          _previousGameScore = game;
        } else {
          _message = summary.sensitive
              ? 'Analisi locale interrotta: controlli sensibili, '
                'incompleti o non leggibili.'
              : 'Controlli accessibili (solo LOCAL, senza dati '
                'dei campi di testo):\n${summary.description}';
        }
      });
    });
  }

  Future<void> _play2048WithLocalAi() async {
    if (!_isWindows || !_session.canInteract ||
        _adapter is! WindowsComputerUseAdapter ||
        _gameRunner?.isRunning == true) {
      return;
    }
    await _run(() async {
      final revision = _session.sessionRevision;
      final windowsAdapter = _adapter;
      final selected = await di.sl<LocalAiRepository>().getSelectedModel();
      final AiModel? model = selected.fold<AiModel?>(
        (_) => null,
        (value) => value,
      );
      if (!_session.canInteract || _session.sessionRevision != revision) {
        return;
      }
      if (model == null || !model.isDownloaded ||
          model.localPath == null || model.localPath!.trim().isEmpty ||
          !await File(model.localPath!).exists()) {
        throw const ComputerUseException(
          'LOCAL_MODEL_UNAVAILABLE',
          'Seleziona prima un modello LOCAL già scaricato e funzionante.',
        );
      }

      final reader = WindowsComputerUseAccessibilityReader(
        session: _session,
        captureAccessibilityJson:
            windowsAdapter.captureSelectedAccessibilityJson,
      );
      final initial = await reader.describe(Uint8List(0));
      final board = initial.sensitive
          ? null
          : ComputerUse2048Benchmark.parse(initial.description);
      if (board == null) {
        throw const ComputerUseException(
          'GAME_NOT_SELECTED',
          'Apri 2048, seleziona la sua finestra e leggine i controlli '
          'prima di avviare l’IA LOCAL.',
        );
      }
      if (!_session.canInteract || _session.sessionRevision != revision) {
        return;
      }

      // Collect structured game-only experiences in memory. No screenshots,
      // files, prompts, Cloud upload, or automatic weight changes.
      final experience = ComputerUse2048ExperienceCollector(maxTransitions: 24);
      // MiniCPM5 may spend additional time on reasoning before its JSON
      // Computer Use move. Keep Qwen's measured limits unchanged.
      final isMiniCpm5 = model.effectiveRuntimeModelId
          .toLowerCase()
          .contains('minicpm5');
      final decisionModel = AivexusComputerUseLocalDecisionModel(
        localRuntime: di.sl<LocalRuntimeProvider>(),
        modelId: model.effectiveRuntimeModelId,
        modelPath: model.localPath!,
        sessionId: 'cu2048-${DateTime.now().microsecondsSinceEpoch}',
        timeout: Duration(seconds: isMiniCpm5 ? 120 : 60),
      );
      final runner = ComputerUseAgentRunner(
        session: _session,
        planner: ComputerUse2048LocalPlanner(
          screenReader: reader,
          model: decisionModel,
          experience: experience,
        ),
        verifier: ComputerUse2048LocalVerifier(
          screenReader: reader,
          experience: experience,
          onObservation: (game) {
            if (!mounted || !_session.canInteract ||
                _session.sessionRevision != revision) return;
            setState(() {
              _previousGameScore = game;
              _message = 'IA LOCAL 2048: ${game.moves} mosse, '
                  'punteggio ${game.score}, '
                  'casella massima ${game.bestTile}. '
                  'Obiettivo: 64.';
            });
          },
        ),
        maxSteps: 24,
        // Repeating LEFT/UP/etc is legitimate when the board changes.
        // The game remains limited to 24 actions; its total time is bounded.
        maxConsecutiveIdenticalActions: 0,
        maxDuration: Duration(minutes: isMiniCpm5 ? 12 : 8),
        operationTimeout: Duration(seconds: isMiniCpm5 ? 135 : 70),
      );
      _gameRunner = runner;
      try {
        final result = await runner.run(
          goal: 'Gioca a 2048 scegliendo le mosse in base alla griglia '
              'osservata per raggiungere almeno una casella 64.',
          onStage: (stage, step) {
            if (mounted && _session.canInteract &&
                _session.sessionRevision == revision) {
              setState(() {
                _message = 'IA LOCAL 2048: fase $stage, '
                    'passo ${step + 1}/24. STOP disponibile.';
              });
            }
          },
        );
        if (!mounted || _session.sessionRevision != revision) return;
        setState(() {
          _message = 'IA LOCAL 2048: risultato ${result.outcome.name}; '
              'mosse tentate ${result.steps}. '
              'Punteggio osservato ${_previousGameScore?.score ?? "non disponibile"}, '
              'casella massima ${_previousGameScore?.bestTile ?? "non disponibile"}. '
              'Esperienze temporanee: ${experience.samples.length}; '
              'mosse osservate: ${experience.observedMoves}. '
              'Nessun addestramento eseguito. '
              'Non interpretare un risultato non verificato come successo.';
        });
      } finally {
        // QA-only: observations are not silently persisted or shared.
        experience.reset();
        if (identical(_gameRunner, runner)) {
          _gameRunner = null;
        }
      }
    });
  }

  Future<void> _captureAfterDelay() async {
    await _run(() async {
      // Capture AFTER the user has switched to the application to observe.
      // A screen capture must not drag focus back to the old target.
      final grantRevision = _session.sessionRevision;
      if (mounted) {
        setState(() => _message =
            'Passa ora alla finestra da osservare: acquisizione tra 4 secondi.');
      }
      await Future<void>.delayed(const Duration(seconds: 4));
      if (!_session.isActive ||
          grantRevision != _session.sessionRevision) return;
      if (_isAndroid) {
        // Bind exactly the currently foreground external app to ONE gesture.
        // The native service excludes settings, system UI and the host app.
        await _androidGestures.invokeMethod<String>(
          'selectForegroundTarget',
        );
      }
      await _refreshFrame();
      if (mounted) {
        setState(() => _message = _isAndroid
            ? 'App selezionata (valida per 3 minuti). Torna in AIVEXUS, tocca o trascina '
              'sull’anteprima e conferma il gesto.'
            : 'Schermata aggiornata. Torna al laboratorio per scegliere '
              'la finestra da controllare.');
      }
    });
  }

  Future<void> _refreshFrame() async {
    final bytes = await _session.captureFrame();
    final data = ByteData.sublistView(bytes);
    if (!mounted) return;
    setState(() {
      _frame = bytes;
      _frameWidth = data.getUint32(16);
      _frameHeight = data.getUint32(20);
    });
  }

  Future<void> _invoke(Map<String, dynamic> params) async {
    await _run(() async {
      final result = await _session.execute(params);
      if (!result.success) {
        throw ComputerUseException(
          result.error ?? 'ACTION_FAILED',
          result.output,
        );
      }
      // Selecting a captured window is passive. Do NOT overwrite the
      // screenshot with Aivexus (now foreground) before the next tap.
      // Other actions can refresh after their target has been focused.
      if (_session.isActive &&
          ComputerUsePreviewPolicy.shouldRefreshAfterAction(
            params['action'] as String?,
          )) {
        await _refreshFrame();
      }
      if (mounted) setState(() => _message = result.output);
    });
  }

  Future<void> _tapFrame(TapUpDetails details, double width) async {
    if (!_session.canInteract || _busy) return;
    final x = (details.localPosition.dx * _frameWidth / width)
        .floor()
        .clamp(0, _frameWidth - 1);
    final y = (details.localPosition.dy * _frameWidth / width)
        .floor()
        .clamp(0, _frameHeight - 1);
    // A passive target selection and a click are separate deliberate
    // actions. The first tap can switch apps without sending mouse input.
    final choosingTarget = _selectTargetOnNextTap;
    if (choosingTarget) {
      setState(() => _selectTargetOnNextTap = false);
    }
    await _invoke(<String, dynamic>{
      'action': choosingTarget ? 'select_window_at' : 'click',
      'x': x,
      'y': y,
    });
  }

  void _stop() {
    _expiryTimer?.cancel();
    _gameRunner?.stop();
    _session.stop();
    if (_isAndroid) {
      unawaited(_androidGestures.invokeMethod<void>('clearTarget'));
    }
    _selectTargetOnNextTap = false;
    _previousGameScore = null;
    unawaited(_releaseProjection());
    if (!mounted) return;
    setState(() {
      _frame = null;
      _message = 'Sessione interrotta.';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ComputerUseLabBuildPolicy.enabled) {
      return Scaffold(
        appBar: AppBar(title: const Text('Computer Use — Laboratorio')),
        body: const Center(
          child: Text('Laboratorio Computer Use non abilitato in questa build.'),
        ),
      );
    }
    final active = _session.isActive;
    final interactive = _session.canInteract;
    return Scaffold(
      appBar: AppBar(title: const Text('Computer Use — Laboratorio')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _isWindows
                ? 'Controlla una finestra alla volta: autorizza, apri e seleziona '
                  'l’app. Aprirla non significa ancora controllarla.'
                : 'Test sperimentale di sola osservazione. '
                  'Permesso schermo richiesto dal sistema operativo; '
                  'mouse, tastiera e agente IA non sono abilitati.',
          ),
          if (_isWindows) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Stato: ${interactive ? 'controllo attivo' : active ? 'sola osservazione' : 'non avviato'}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '1. Avvia controllo e autorizza.\n'
                      '2. Apri un’applicazione.\n'
                      '3. Seleziona la sua finestra (4 secondi).\n'
                      '4. Torna qui per scrivere, cliccare o premere tasti.\n'
                      'Per verificare usa la prova guidata Blocco note.',
                    ),
                    if (active && !interactive)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'Sei in sola osservazione: premi STOP e avvia il controllo per usare mouse e tastiera.',
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (_isAndroid) ...[
            const SizedBox(height: 8),
            const Text(
              'Computer Use Android: seleziona l’app che vuoi osservare, '
              'poi autorizza un tocco o uno scorrimento. '
              'Per ora non è ancora attivo un agente IA autonomo.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _appSearchController,
              decoration: const InputDecoration(
                labelText: 'Cerca un’app installata',
                hintText: 'Per esempio: Car Jam, Note, Blocco note',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _findAndOpenAndroidApp(),
            ),
            FilledButton.icon(
              onPressed: _busy ? null : _findAndOpenAndroidApp,
              icon: const Icon(Icons.apps),
              label: const Text('Cerca e apri app'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _textController,
              maxLength: 512,
              decoration: const InputDecoration(
                labelText: 'Testo da inserire nell’app selezionata',
                border: OutlineInputBorder(),
              ),
            ),
            OutlinedButton.icon(
              onPressed: !_busy && active ? _typeAndroidSelectedText : null,
              icon: const Icon(Icons.edit_note),
              label: const Text('Inserisci testo nel campo attivo'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _openAndroidAccessibilitySettings,
              icon: const Icon(Icons.accessibility_new),
              label: const Text('Autorizza tocchi in Accessibilità Android'),
            ),
            const Text(
              'La selezione dell’app dura 3 minuti. Se scade, premi di nuovo '
              'Acquisisci tra 4 secondi. Il testo viene scritto solo nel '
              'campo modificabile identificato da Android; con più campi '
              'ambigui AIVEXUS non sceglie al tuo posto.',
            ),
            const Text(
              'Dopo aver abilitato il servizio, avvia Solo osservazione, '
              'premi Acquisisci tra 4 secondi e apri l’app da controllare. '
              'Tocca o trascina sull’anteprima e conferma, poi torna '
              'nell’app entro 4 secondi per vedere il gesto.',
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _openCarJamPlayStore,
              icon: const Icon(Icons.shop_outlined),
              label: const Text('Car Jam Solver — apri su Google Play'),
            ),
            const Text(
              'Installazione solo con tua conferma nel Play Store. '
              'Car Jam è solo un’applicazione suggerita per il primo collaudo. '
              'L’agente autonomo Android non è ancora disponibile.',
            ),
          ],
          const SizedBox(height: 12),
          if (!_session.isSupported)
            const Text('Computer Use non disponibile su questa piattaforma.')
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: !_busy && !active
                      ? () => _begin(interactive: false)
                      : null,
                  child: const Text('Solo osservazione'),
                ),
                if (_canInput)
                  FilledButton(
                    onPressed: !_busy && !active
                        ? () => _begin(interactive: true)
                        : null,
                    child: const Text('1. Avvia controllo'),
                  ),
                OutlinedButton(
                  onPressed: !_busy && active
                      ? () => _run(_refreshFrame)
                      : null,
                  child: const Text('Aggiorna schermata'),
                ),
                if (_isWindows || _isAndroid) ...[
                  OutlinedButton(
                    onPressed: !_busy && active
                        ? _captureAfterDelay
                        : null,
                    child: const Text('Acquisisci tra 4 secondi'),
                  ),
                  if (_isWindows) OutlinedButton(
                    onPressed: !_busy && active
                        ? _readWindowsAccessibility
                        : null,
                    child: const Text('Leggi controlli finestra (LOCAL)'),
                  ),
                ],
                OutlinedButton(
                  onPressed: active ? _stop : null,
                  child: const Text('STOP'),
                ),
              ],
            ),
            if (interactive) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy ? null : _runAutomaticSmokeTest,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Prova guidata: scrivi in Blocco note'),
              ),
              const Text(
                'La prova guidata seleziona la finestra e verifica davvero '
                'che il testo venga scritto: aprire l’app da solo non basta.',
              ),
              const Text(
                'Apre Blocco note, scrive un testo di prova e verifica '
                'il risultato tramite accessibilita Windows. '
                'STOP resta disponibile durante la prova.',
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _invoke(<String, dynamic>{
                              'action': 'open_app',
                              'app': 'notepad',
                            }),
                    icon: const Icon(Icons.notes_outlined),
                    label: const Text('2. Apri Blocco note'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _invoke(<String, dynamic>{
                              'action': 'open_app',
                              'app': 'calculator',
                            }),
                    icon: const Icon(Icons.calculate_outlined),
                    label: const Text('2. Apri Calcolatrice'),
                  ),
                  if (_isWindows) ...[
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _invoke(<String, dynamic>{
                                'action': 'open_app',
                                'app': 'paint',
                              }),
                      icon: const Icon(Icons.brush_outlined),
                      label: const Text('2. Apri Paint'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _invoke(<String, dynamic>{
                                'action': 'open_app',
                                'app': 'qa2048',
                              }),
                      icon: const Icon(Icons.sports_esports_outlined),
                      label: const Text('2. Apri 2048 (sperimentale)'),
                    ),
                  ],
                ],
              ),
              if (_isWindows) ...[
                FilledButton.icon(
                  onPressed: _busy ? null : _play2048WithLocalAi,
                  icon: const Icon(Icons.psychology_outlined),
                  label: const Text('4. Fai giocare AIVEXUS a 2048'),
                ),
                const Text(
                  'Esperimento di ragionamento reale: apri 2048, '
                  'seleziona la sua finestra e poi avvia il modello LOCAL '
                  'già scaricato. L’IA sceglie solo le frecce, massimo '
                  '24 mosse; il punteggio è letto indipendentemente '
                  'dalla finestra di gioco. STOP annulla anche l’inferenza. '
                  'Funzione sperimentale, non ancora provata su ASUS.',
                ),
              ],
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _selectTargetWindow,
                icon: const Icon(Icons.select_all_outlined),
                label: const Text('3. Seleziona finestra (4 secondi)'),
              ),
              const Text(
                'Premi il pulsante e passa entro 4 secondi alla finestra da '
                'controllare. Poi torna qui e prova un comando.',
              ),
              if (_isWindows) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy || _frame == null
                      ? null
                      : () => setState(() {
                          _selectTargetOnNextTap = !_selectTargetOnNextTap;
                        }),
                  icon: const Icon(Icons.open_with),
                  label: Text(_selectTargetOnNextTap
                      ? 'Annulla scelta finestra'
                      : 'Scegli altra finestra dalla schermata'),
                ),
                const Text(
                  'Porta prima l’app desiderata in primo piano e usa '
                  '“Acquisisci tra 4 secondi”. Tornato qui, scegli un punto '
                  'di quella finestra nella cattura. Questo primo tocco '
                  'seleziona SENZA cliccare; un secondo tocco può cliccare. '
                  'Per passare a un’altra app, acquisiscila di nuovo.',
                ),
              ],
            ],
            if (active && _session.expiresAt != null) ...[
              const SizedBox(height: 8),
              Text('Scadenza sessione: ${_session.expiresAt!.hour.toString().padLeft(2, '0')}:'
                  '${_session.expiresAt!.minute.toString().padLeft(2, '0')}'),
            ],
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            Text(_message),
            const SizedBox(height: 12),
            if (_frame != null && active)
              LayoutBuilder(
                builder: (context, box) => AspectRatio(
                  aspectRatio: _frameWidth / _frameHeight,
                  child: GestureDetector(
                    onTapUp: interactive && !_busy
                        ? (details) => _tapFrame(details, box.maxWidth)
                        : _isAndroid && active && !_busy
                            ? (details) => _tapAndroidGameFrame(
                                details, box.maxWidth)
                            : null,
                    onPanStart: _isAndroid && active && !_busy
                        ? (details) {
                            _androidPanStart = details.localPosition;
                            _androidPanLast = details.localPosition;
                          }
                        : null,
                    onPanUpdate: _isAndroid && active && !_busy
                        ? (details) => _androidPanLast = details.localPosition
                        : null,
                    onPanEnd: _isAndroid && active && !_busy
                        ? (_) {
                            final start = _androidPanStart;
                            final end = _androidPanLast;
                            _androidPanStart = null;
                            _androidPanLast = null;
                            if (start != null && end != null) {
                              _sendAndroidGameGesture(start, end, box.maxWidth);
                            }
                          }
                        : null,
                    child: Image.memory(
                      _frame!,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.low,
                    ),
                  ),
                ),
              ),
            if (interactive) ...[
              const SizedBox(height: 16),
              const Text('4. Interagisci con la finestra selezionata. '
                  'Se non succede nulla, prova prima il test guidato Blocco note.'),
              const SizedBox(height: 8),
              TextField(
                controller: _textController,
                onChanged: (_) => setState(() {}),
                maxLength: 512,
                decoration: const InputDecoration(
                  labelText: 'Testo da inserire nella finestra selezionata',
                  border: OutlineInputBorder(),
                ),
              ),
              FilledButton(
                onPressed: _busy || _textController.text.isEmpty
                    ? null
                    : () async {
                        final value = _textController.text;
                        await _invoke(<String, dynamic>{
                          'action': 'type_text',
                          'text': value,
                        });
                        if (mounted && _message ==
                            'Text entered into the active window.') {
                          _textController.clear();
                        }
                      },
                child: const Text('Inserisci testo'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final key in ComputerUseSession.allowedKeys.toList()
                      ..sort())
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _invoke(<String, dynamic>{
                                'action': 'press_key',
                                'key': key,
                              }),
                      child: Text(key),
                    ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}
