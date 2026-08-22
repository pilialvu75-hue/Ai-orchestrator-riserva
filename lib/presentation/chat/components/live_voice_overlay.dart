import 'dart:async';

import 'package:flutter/material.dart';

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/voice_loop_manager.dart';
import 'package:ai_orchestrator/core/voice/voice_model_downloader.dart';

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
      const Duration(milliseconds: 200),
      (_) {
        if (!mounted || _closing) {
          return;
        }

        _syncUiStateFromEngine();
      },
    );

    // Never start native voice initialization synchronously from initState.
    // The first Flutter frame must be committed first.
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

    // VoiceLoopManager owns the live-session lifecycle.
    // VoiceEngine is a DI singleton and must not be disposed here.
    unawaited(_safeStopLiveSession());

    _uiState.dispose();

    super.dispose();
  }

  Future<void> _safeStopLiveSession() async {
    try {
      await widget.voiceLoopManager.stopLiveSession();
    } catch (_) {
      // Native shutdown must never escape widget disposal.
    }
  }

  Future<void> _startSession() async {
    if (!mounted || _closing || _starting || _sessionStarted) {
      return;
    }

    _starting = true;

    _log('[START]');

    try {
      /*
       * IMPORTANT:
       *
       * Do NOT use VoiceEngine.inspect() as the source of truth for model
       * availability.
       *
       * inspect() returns the cached status. On a fresh engine that status can
       * legitimately be "unsupported/uninitialized" even when the voice
       * models are already present on disk.
       *
       * Therefore the authoritative operation here is initialize().
       */

      _log('[ENGINE_INIT]');

      VoiceEngineStatus status;

      try {
        status = await widget.voiceEngine.initialize();
      } catch (error) {
        if (!mounted || _closing) {
          return;
        }

        _showError(
          'Inizializzazione del motore vocale non riuscita: $error',
        );
        return;
      }

      if (!mounted || _closing) {
        return;
      }

      /*
       * If the engine initialized correctly, never enter the downloader
       * pipeline. The downloader is only a recovery path for genuinely
       * missing voice assets.
       */
      if (status.readyForInput && status.readyForOutput) {
        _log('[ENGINE_READY]');

        _startLiveLoop();
        return;
      }

      /*
       * If initialization failed because voice resources are missing,
       * attempt the download pipeline exactly once.
       *
       * We deliberately do NOT trigger the downloader merely because
       * inspect()/cached status says isVoiceDownloaded=false.
       */
      if (_looksLikeMissingVoiceAssets(status)) {
        _log('[ASSETS_MISSING]');

        await _runModelDownloadPipeline();

        if (!mounted || _closing) {
          return;
        }

        /*
         * Reinitialize after downloading. The same VoiceEngine instance is
         * retained so DI ownership and lifecycle remain unchanged.
         */
        _log('[ENGINE_REINIT]');

        status = await widget.voiceEngine.initialize();

        if (!mounted || _closing) {
          return;
        }

        if (status.readyForInput && status.readyForOutput) {
          _log('[ENGINE_READY_AFTER_DOWNLOAD]');

          _startLiveLoop();
          return;
        }
      }

      /*
       * At this point initialization completed without a usable complete
       * voice-to-voice configuration.
       *
       * Do not enter VoiceLoopManager. This prevents the loop from reaching
       * microphone/STT/TTS in an invalid state.
       */
      _showStatusError(status);
    } catch (error) {
      if (!mounted || _closing) {
        return;
      }

      _log('[START_ERROR]');

      _showError(
        'Live Mode non può essere avviato: $error',
      );
    } finally {
      _starting = false;

      if (mounted && !_closing) {
        _syncUiStateFromEngine();
      }
    }
  }

  bool _looksLikeMissingVoiceAssets(VoiceEngineStatus status) {
    final details = (status.details ?? '').trim().toLowerCase();

    if (status.offlineAsrAvailable || status.offlineTtsAvailable) {
      return false;
    }

    return details.contains('risorse vocali mancanti') ||
        details.contains('modelli vocali mancanti') ||
        details.contains('modelli mancanti') ||
        details.contains('risorse vocali') ||
        details.contains('voice assets') ||
        details.contains('missing');
  }

  void _showStatusError(VoiceEngineStatus status) {
    if (!mounted || _closing) {
      return;
    }

    final detail = (status.details ?? '').trim();

    if (!status.microphonePermissionGranted) {
      _showError(
        detail.isEmpty
            ? 'Live Mode richiede il permesso di usare il microfono.'
            : 'Live Mode: $detail',
      );
      return;
    }

    if (!status.offlineAsrAvailable) {
      _showError(
        detail.isEmpty
            ? 'Riconoscimento vocale non disponibile. '
                'Verifica i modelli STT.'
            : 'Live Mode: $detail',
      );
      return;
    }

    if (!status.offlineTtsAvailable) {
      _showError(
        detail.isEmpty
            ? 'Sintesi vocale non disponibile. '
                'Verifica i modelli TTS.'
            : 'Live Mode: $detail',
      );
      return;
    }

    _showError(
      detail.isEmpty
          ? 'Motore vocale non pronto per Live Mode.'
          : 'Live Mode: $detail',
    );
  }

  Future<void> _runModelDownloadPipeline() async {
    if (!mounted || _closing || _isDownloadingModels) {
      return;
    }

    setState(() {
      _isDownloadingModels = true;
      _downloadProgress = 0;
      _downloadStatus = 'Preparazione modelli vocali...';
      _error = null;
    });

    try {
      /*
       * Permission/download is deliberately reached only after initialize()
       * has established that the voice assets are actually missing.
       */
      final hasPermissions =
          await widget.voiceModelDownloader.checkAndRequestPermissions();

      if (!hasPermissions) {
        throw const VoiceAssetException(
          'Impossibile preparare i modelli vocali.',
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

      _log('[DOWNLOAD_OK]');
    } catch (error) {
      if (!mounted || _closing) {
        return;
      }

      setState(() {
        _isDownloadingModels = false;
        _error = 'Download modelli vocali non riuscito: $error';
      });

      rethrow;
    }
  }

  void _startLiveLoop() {
    if (!mounted || _closing || _sessionStarted) {
      return;
    }

    _syncUiStateFromEngine();

    _sessionStarted = true;

    _log('[LOOP_START]');

    unawaited(
      _runLiveLoop(),
    );
  }

  Future<void> _runLiveLoop() async {
    try {
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
    } catch (error) {
      if (!mounted || _closing) {
        return;
      }

      _showError(
        'Errore durante la sessione Live: $error',
      );
    } finally {
      if (mounted && !_closing) {
        _sessionStarted = false;
        _syncUiStateFromEngine();
      }
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

    final normalized = message.trim();

    setState(() {
      _error = normalized.isEmpty
          ? 'Errore del sistema vocale.'
          : normalized;
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

    _stateTicker?.cancel();
    _stateTicker = null;

    try {
      await widget.voiceLoopManager.stopLiveSession();
    } catch (_) {
      // Never prevent the overlay from closing.
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
                            valueColor: AlwaysStoppedAnimation<Color>(
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
