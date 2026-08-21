import 'dart:async';

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/voice_loop_manager.dart';
import 'package:ai_orchestrator/core/voice/voice_model_downloader.dart';
import 'package:flutter/material.dart';

enum _LiveVoiceUiState {
  listening,
  thinking,
  speaking,
  idle,
}

class LiveVoiceOverlay extends StatefulWidget {
  const LiveVoiceOverlay({
    super.key,
    required this.voiceLoopManager,
    required this.voiceEngine,
    required this.voiceModelDownloader,
  });

  final VoiceLoopManager voiceLoopManager;
  final VoiceEngine voiceEngine;
  final VoiceModelDownloader voiceModelDownloader;

  @override
  State<LiveVoiceOverlay> createState() => _LiveVoiceOverlayState();
}

class _LiveVoiceOverlayState extends State<LiveVoiceOverlay> {
  final ValueNotifier<_LiveVoiceUiState> _uiState =
      ValueNotifier<_LiveVoiceUiState>(_LiveVoiceUiState.idle);

  Timer? _stateTicker;

  bool _closing = false;
  bool _starting = false;
  bool _sessionStarted = false;
  bool _isDownloadingModels = false;

  String? _error;

  double _downloadProgress = 0;

  String _downloadStatus = 'Preparazione download modelli vocali...';

  @override
  void initState() {
    super.initState();

    _stateTicker = Timer.periodic(
      const Duration(milliseconds: 150),
      (_) {
        if (!mounted || _closing) {
          return;
        }

        _syncUiStateFromEngine();
      },
    );

    // Do not initialize native audio/Sherpa synchronously from initState.
    //
    // The first frame must be committed before entering the native voice
    // initialization path. This also makes the lifecycle deterministic.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closing) {
        return;
      }

      unawaited(_startSession());
    });
  }

  @override
  void dispose() {
    _closing = true;

    _stateTicker?.cancel();
    _stateTicker = null;

    // VoiceLoopManager owns the live-session lifecycle. The VoiceEngine itself
    // is a DI singleton and must NOT be disposed by this overlay.
    unawaited(
      widget.voiceLoopManager.stopLiveSession(),
    );

    _uiState.dispose();

    super.dispose();
  }

  Future<void> _startSession() async {
    if (!mounted || _closing || _starting || _sessionStarted) {
      return;
    }

    _starting = true;

    _log('[INIT_BEGIN]');

    try {
      /*
       * ---------------------------------------------------------------------
       * STEP 1 — Inspect only
       * ---------------------------------------------------------------------
       *
       * Do not initialize the native engine until the overlay is fully
       * mounted and the current state has been inspected.
       */
      final inspectedStatus = await widget.voiceEngine.inspect();

      if (!mounted || _closing) {
        return;
      }

      /*
       * A cached unsupported/uninitialized status is NOT considered a failure.
       * initialize() is responsible for creating the native Sherpa runtime.
       */
      if (_requiresModelsDownload(inspectedStatus)) {
        await _runModelDownloadPipeline();

        if (!mounted || _closing) {
          return;
        }
      }

      /*
       * ---------------------------------------------------------------------
       * STEP 2 — Native voice initialization
       * ---------------------------------------------------------------------
       *
       * This is intentionally kept as one isolated await.
       *
       * If the process dies here, the next log boundary tells us that the
       * failure is inside Sherpa/native voice initialization and NOT in:
       *
       *   VoiceLoopManager
       *   inference
       *   prompt construction
       *   memory
       *   TTS playback after inference
       */
      _log('[ENGINE_INIT_BEGIN]');

      final status = await widget.voiceEngine.initialize();

      if (!mounted || _closing) {
        return;
      }

      _log(
        '[ENGINE_INIT_RESULT] '
        'initialized=${status.initialized} '
        'stt=${status.offlineAsrAvailable} '
        'tts=${status.offlineTtsAvailable} '
        'mic=${status.microphonePermissionGranted}',
      );

      /*
       * ---------------------------------------------------------------------
       * STEP 3 — Live requires INPUT
       * ---------------------------------------------------------------------
       *
       * The previous implementation checked readyForOutput too, which is
       * correct for a complete voice-to-voice session, but we must first
       * establish that STT/microphone is actually available.
       */
      if (!status.readyForInput) {
        final detail = (status.details ?? '').trim();

        final message = detail.isEmpty
            ? 'Live Mode non può avviarsi: microfono o riconoscimento vocale non disponibili.'
            : 'Live Mode non può avviarsi: $detail';

        _log('[ENGINE_NOT_READY] $message');

        _showError(message);
        return;
      }

      /*
       * TTS must also be ready because Live is voice-to-voice.
       */
      if (!status.readyForOutput) {
        const message =
            'Live Mode non può avviarsi: uscita vocale non disponibile.';

        _log('[ENGINE_OUTPUT_NOT_READY] $message');

        _showError(message);
        return;
      }

      /*
       * Validate downloaded assets after initialize(), not before native
       * initialization. This avoids using a stale VoiceEngineStatus snapshot
       * as the source of truth.
       */
      _log('[ASSET_CHECK_BEGIN]');

      await widget.voiceModelDownloader.validateDownloadedAssets();

      if (!mounted || _closing) {
        return;
      }

      _log('[ASSET_CHECK_OK]');

      /*
       * ---------------------------------------------------------------------
       * STEP 4 — Start Live loop
       * ---------------------------------------------------------------------
       */
      _syncUiStateFromEngine();

      _log('[LOOP_START_BEGIN]');

      _sessionStarted = true;

      await widget.voiceLoopManager.startLiveSession(
        onError: (message) {
          if (!mounted || _closing) {
            return;
          }

          _showError(message);
          _syncUiStateFromEngine();
        },
        onSubtitle: (_, __) {
          if (!mounted || _closing) {
            return;
          }

          _syncUiStateFromEngine();
        },
      );

      if (!mounted || _closing) {
        return;
      }

      _log('[LOOP_END]');

      _syncUiStateFromEngine();
    } catch (error) {
      if (!mounted || _closing) {
        return;
      }

      _log('[INIT_ERROR] $error');

      _showError('$error');
    } finally {
      _starting = false;

      if (mounted && !_closing) {
        _syncUiStateFromEngine();
      }
    }
  }

  bool _requiresModelsDownload(VoiceEngineStatus status) {
    final details = (status.details ?? '').toLowerCase();

    return !status.isVoiceDownloaded ||
        details.contains('modelli mancanti') ||
        details.contains('risorse vocali mancanti');
  }

  Future<void> _runModelDownloadPipeline() async {
    if (!mounted || _closing) {
      return;
    }

    setState(() {
      _isDownloadingModels = true;
      _downloadProgress = 0;
      _downloadStatus = 'Preparazione archivio modelli vocali...';
      _error = null;
    });

    try {
      final hasPermissions =
          await widget.voiceModelDownloader.checkAndRequestPermissions();

      if (!hasPermissions) {
        throw const VoiceAssetException(
          'Impossibile preparare l’archivio dei modelli vocali.',
        );
      }

      if (!mounted || _closing) {
        return;
      }

      setState(() {
        _downloadStatus = 'Scaricamento modelli vocali: 0%';
      });

      await widget.voiceModelDownloader.downloadModels(
        onProgress: (value) {
          if (!mounted || _closing) {
            return;
          }

          final normalized = value.clamp(0.0, 1.0).toDouble();

          setState(() {
            _downloadProgress = normalized;
            _downloadStatus =
                'Scaricamento modelli vocali: '
                '${(normalized * 100).toStringAsFixed(0)}%';
          });
        },
      );

      if (!mounted || _closing) {
        return;
      }

      setState(() {
        _downloadProgress = 1;
        _downloadStatus =
            'Download completato. Inizializzazione motore...';
        _isDownloadingModels = false;
      });

      _log('[DOWNLOAD_COMPLETE]');
    } catch (error) {
      if (!mounted || _closing) {
        return;
      }

      setState(() {
        _isDownloadingModels = false;
      });

      rethrow;
    }
  }

  _LiveVoiceUiState _deriveUiState() {
    if (widget.voiceEngine.isListening) {
      return _LiveVoiceUiState.listening;
    }

    if (widget.voiceEngine.isSpeaking) {
      return _LiveVoiceUiState.speaking;
    }

    if (widget.voiceLoopManager.isSessionActive) {
      return _LiveVoiceUiState.thinking;
    }

    return _LiveVoiceUiState.idle;
  }

  void _syncUiStateFromEngine() {
    if (!mounted || _isDownloadingModels) {
      return;
    }

    final next = _deriveUiState();

    if (_uiState.value != next) {
      _uiState.value = next;
    }
  }

  void _showError(String message) {
    if (!mounted || _closing) {
      return;
    }

    setState(() {
      _error = message;
      _isDownloadingModels = false;
    });

    _uiState.value = _LiveVoiceUiState.idle;
  }

  void _log(String message) {
    RuntimeEventLog.instance.emit('[VOICE_LIVE] $message');
  }

  Future<void> _closeOverlay() async {
    if (_closing) {
      return;
    }

    _closing = true;

    try {
      await widget.voiceLoopManager.stopLiveSession();
    } catch (_) {
      // Native audio shutdown must never prevent the overlay from closing.
    }

    if (!mounted) {
      return;
    }

    Navigator.of(context).pop();
  }

  String _statusLabel(_LiveVoiceUiState state) {
    switch (state) {
      case _LiveVoiceUiState.listening:
        return 'Ti ascolto...';

      case _LiveVoiceUiState.thinking:
        return 'Sto pensando...';

      case _LiveVoiceUiState.speaking:
        return "L'assistente parla...";

      case _LiveVoiceUiState.idle:
        return 'Sessione in attesa...';
    }
  }

  Color _statusColor(_LiveVoiceUiState state) {
    switch (state) {
      case _LiveVoiceUiState.listening:
        return const Color(0xFF4ADE80);

      case _LiveVoiceUiState.thinking:
        return const Color(0xFFF9A826);

      case _LiveVoiceUiState.speaking:
        return const Color(0xFF8AB4F8);

      case _LiveVoiceUiState.idle:
        return const Color(0xFF9CA3AF);
    }
  }

  List<Widget> _buildErrorWidgetsIfPresent(String errorText) {
    if (errorText.isEmpty) {
      return const <Widget>[];
    }

    return [
      const SizedBox(height: 12),
      Text(
        errorText,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFFFF8A80),
          fontSize: 13,
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 24, 12, 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF0A0F1B).withValues(alpha: 0.94),
                  const Color(0xFF05070D).withValues(alpha: 0.98),
                ],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
              child: ValueListenableBuilder<_LiveVoiceUiState>(
                valueListenable: _uiState,
                builder: (context, state, _) {
                  final errorText = _error?.trim() ?? '';

                  if (_isDownloadingModels) {
                    return Column(
                      children: [
                        Container(
                          width: 52,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        const Spacer(),
                        const SizedBox(
                          width: 96,
                          height: 96,
                          child: CircularProgressIndicator(
                            strokeWidth: 4,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(
                              Color(0xFF8AB4F8),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          _downloadStatus,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 18),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            value: _downloadProgress,
                            minHeight: 10,
                            backgroundColor:
                                Colors.white.withValues(alpha: 0.14),
                            valueColor:
                                const AlwaysStoppedAnimation<Color>(
                              Color(0xFF8AB4F8),
                            ),
                          ),
                        ),
                        ..._buildErrorWidgetsIfPresent(errorText),
                        const Spacer(),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor:
                                  const Color(0xFFDC2626),
                              foregroundColor: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 18),
                            ),
                            onPressed: _closeOverlay,
                            icon: const Icon(
                              Icons.call_end_rounded,
                            ),
                            label: const Text(
                              'Termina sessione live',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  }

                  final statusColor = _statusColor(state);
                  final isActive =
                      state != _LiveVoiceUiState.idle;

                  return Column(
                    children: [
                      Container(
                        width: 52,
                        height: 4,
                        decoration: BoxDecoration(
                          color:
                              Colors.white.withValues(alpha: 0.2),
                          borderRadius:
                              BorderRadius.circular(999),
                        ),
                      ),
                      const Spacer(),
                      AnimatedContainer(
                        duration:
                            const Duration(milliseconds: 220),
                        width: isActive ? 132 : 96,
                        height: isActive ? 132 : 96,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              statusColor.withValues(alpha: 0.12),
                          border: Border.all(
                            color:
                                statusColor.withValues(alpha: 0.8),
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  statusColor.withValues(alpha: 0.35),
                              blurRadius: 28,
                              spreadRadius: 3,
                            ),
                          ],
                        ),
                        child: Icon(
                          state ==
                                  _LiveVoiceUiState.speaking
                              ? Icons.volume_up_rounded
                              : Icons.graphic_eq_rounded,
                          size: 46,
                          color: statusColor,
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        _statusLabel(state),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      ..._buildErrorWidgetsIfPresent(errorText),
                      const Spacer(),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                const Color(0xFFDC2626),
                            foregroundColor: Colors.white,
                            padding:
                                const EdgeInsets.symmetric(vertical: 18),
                          ),
                          onPressed: _closeOverlay,
                          icon: const Icon(
                            Icons.call_end_rounded,
                          ),
                          label: const Text(
                            'Termina sessione live',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
