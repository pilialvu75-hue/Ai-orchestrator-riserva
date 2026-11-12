import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_build_policy.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_session.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_smoke_scenario.dart';
import 'package:ai_orchestrator/features/computer_use/android_computer_use_adapter.dart';
import 'package:ai_orchestrator/features/computer_use/mac_computer_use_adapter.dart';
import 'package:ai_orchestrator/features/computer_use/windows_computer_use_adapter.dart';

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

  Uint8List? _frame;
  int _frameWidth = 1;
  int _frameHeight = 1;
  bool _busy = false;
  bool _selectTargetOnNextTap = false;
  String _message = 'Nessuna sessione attiva.';

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _session.stop();
    unawaited(_releaseProjection());
    _textController.dispose();
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
      if (_session.isActive) await _refreshFrame();
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
    _session.stop();
    _selectTargetOnNextTap = false;
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
                ? 'Test Windows locale: schermata, clic, testo e navigazione. '
                  'Nessuna esecuzione di shell o invio automatico di immagini.'
                : 'Test sperimentale di sola osservazione. '
                  'Permesso schermo richiesto dal sistema operativo; '
                  'mouse, tastiera e agente IA non sono abilitati.',
          ),
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
                  child: const Text('Osserva schermo'),
                ),
                if (_canInput)
                  FilledButton(
                    onPressed: !_busy && !active
                        ? () => _begin(interactive: true)
                        : null,
                    child: const Text('Abilita interazione'),
                  ),
                OutlinedButton(
                  onPressed: !_busy && active
                      ? () => _run(_refreshFrame)
                      : null,
                  child: const Text('Aggiorna'),
                ),
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
                label: const Text('Test automatico: Blocco note'),
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
                    label: const Text('Apri Blocco note'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _invoke(<String, dynamic>{
                              'action': 'open_app',
                              'app': 'calculator',
                            }),
                    icon: const Icon(Icons.calculate_outlined),
                    label: const Text('Apri Calcolatrice'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _selectTargetWindow,
                icon: const Icon(Icons.select_all_outlined),
                label: const Text('Seleziona finestra attiva (4 secondi)'),
              ),
              const Text(
                'Premi il pulsante, poi passa subito a Blocco note. '
                'La selezione non richiede password né privilegi elevati.',
              ),
              if (_isWindows) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy || _frame == null
                      ? null
                      : () => setState(() {
                          _selectTargetOnNextTap = !_selectTargetOnNextTap;
                        }),
                  icon: const Icon(Icons.open_with_outlined),
                  label: Text(_selectTargetOnNextTap
                      ? 'Annulla scelta finestra'
                      : 'Scegli altra finestra dalla schermata'),
                ),
                const Text(
                  'Dopo aver aggiornato la schermata, scegli il bersaglio '
                  'con un tocco. La scelta NON clicca: soltanto un secondo '
                  'tocco esegue un clic nella finestra selezionata. '
                  'Puoi ripetere la scelta per passare ad altre applicazioni.',
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
              const Text('Seleziona prima la finestra da controllare. '
                  'Poi torna qui per inviare testo o tasti; '
                  'Aivexus riattiverà la finestra scelta.'),
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
