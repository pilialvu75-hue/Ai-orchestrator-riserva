import 'dart:async';

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/voice_loop_manager.dart';
import 'package:ai_orchestrator/core/voice/voice_model_downloader.dart';
import 'package:flutter/material.dart';

enum _LiveVoiceUiState { listening, thinking, speaking, idle }

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
      ValueNotifier<_LiveVoiceUiState>(_LiveVoiceUiState.thinking);
  Timer? _stateTicker;
  bool _closing = false;
  bool _isDownloadingModels = false;
  String? _error;
  double _downloadProgress = 0;
  String _downloadStatus = 'Preparazione download modelli vocali...';

  @override
  void initState() {
    super.initState();
    _stateTicker = Timer.periodic(
      const Duration(milliseconds: 120),
      (_) => _syncUiStateFromEngine(),
    );
    unawaited(_startSession());
  }

  @override
  void dispose() {
    _stateTicker?.cancel();
    _uiState.dispose();
    unawaited(widget.voiceLoopManager.stopLiveSession());
    super.dispose();
  }

  Future<void> _startSession() async {
    try {
      var status = await widget.voiceEngine.initialize();
      if (_requiresModelsDownload(status)) {
        await _runModelDownloadPipeline();
        if (!mounted) return;
        status = await widget.voiceEngine.initialize();
      }
      await _ensureLiveModeStartupReady(status);
      if (!mounted) return;
      _syncUiStateFromEngine();
      unawaited(
        widget.voiceLoopManager.startLiveSession(
          onError: (message) {
            if (!mounted) return;
            setState(() {
              _error = message;
            });
            _syncUiStateFromEngine();
          },
          onSubtitle: (_, __) {
            if (!mounted) return;
            _syncUiStateFromEngine();
          },
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _isDownloadingModels = false;
      });
      _uiState.value = _LiveVoiceUiState.idle;
    }
  }

  bool _requiresModelsDownload(VoiceEngineStatus status) {
    final details = (status.details ?? '').toLowerCase();
    return !status.isVoiceDownloaded ||
        details.contains('modelli mancanti') ||
        details.contains('risorse vocali mancanti');
  }

  Future<void> _ensureLiveModeStartupReady(VoiceEngineStatus status) async {
    RuntimeEventLog.instance.emit(
      '[VOICE_LIVE_ASSET_CHECK_BEGIN] validating voice assets before Live Mode startup',
    );
    await widget.voiceModelDownloader.validateDownloadedAssets();

    if (!status.isVoiceDownloaded) {
      const message =
          'I modelli vocali richiesti non sono disponibili. Completa di nuovo il download dei modelli vocali prima di avviare Live Mode.';
      RuntimeEventLog.instance.emit('[VOICE_LIVE_ASSET_CHECK_FAIL] $message');
      throw const VoiceAssetException(message);
    }

    if (!status.readyForInput || !status.readyForOutput) {
      final detail = (status.details ?? '').trim();
      final message = detail.isEmpty
          ? 'Live Mode richiede modelli vocali validi e accesso al microfono. Verifica il download dei modelli vocali e i permessi microfono, poi riprova.'
          : 'Live Mode non può avviarsi: $detail';
      RuntimeEventLog.instance.emit('[VOICE_LIVE_ASSET_CHECK_FAIL] $message');
      throw VoiceAssetException(message);
    }

    RuntimeEventLog.instance.emit(
      '[VOICE_LIVE_ASSET_CHECK_COMPLETE] voice assets verified for Live Mode startup',
    );
  }

  Future<void> _runModelDownloadPipeline() async {
    setState(() {
      _isDownloadingModels = true;
      _downloadProgress = 0;
      _downloadStatus = 'Preparazione archivio modelli vocali...';
      _error = null;
    });

    final hasPermissions =
        await widget.voiceModelDownloader.checkAndRequestPermissions();
    if (!hasPermissions) {
      throw const VoiceAssetException(
        'Impossibile preparare l’archivio dei modelli vocali.',
      );
    }

    if (!mounted) return;
    setState(() {
      _downloadStatus = 'Scaricamento modelli vocali: 0%';
    });

    await widget.voiceModelDownloader.downloadModels(
      onProgress: (value) {
        if (!mounted) return;
        final normalized = value.clamp(0.0, 1.0).toDouble();
        setState(() {
          _downloadProgress = normalized;
          _downloadStatus =
              'Scaricamento modelli vocali: ${(normalized * 100).toStringAsFixed(0)}%';
        });
      },
    );

    if (!mounted) return;
    setState(() {
      _downloadProgress = 1;
      _downloadStatus = 'Download completato. Inizializzazione motore...';
      _isDownloadingModels = false;
    });
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
    if (_isDownloadingModels) {
      return;
    }
    final next = _deriveUiState();
    if (_uiState.value != next) {
      _uiState.value = next;
    }
  }

  Future<void> _closeOverlay() async {
    if (_closing) return;
    _closing = true;
    await widget.voiceLoopManager.stopLiveSession();
    if (!mounted) return;
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
    if (errorText.isEmpty) return const <Widget>[];
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
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
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
                              backgroundColor: const Color(0xFFDC2626),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 18),
                            ),
                            onPressed: _closeOverlay,
                            icon: const Icon(Icons.call_end_rounded),
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
                  final isActive = state != _LiveVoiceUiState.idle;
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
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        width: isActive ? 132 : 96,
                        height: isActive ? 132 : 96,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: statusColor.withValues(alpha: 0.12),
                          border: Border.all(
                            color: statusColor.withValues(alpha: 0.8),
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: statusColor.withValues(alpha: 0.35),
                              blurRadius: 28,
                              spreadRadius: 3,
                            ),
                          ],
                        ),
                        child: Icon(
                          state == _LiveVoiceUiState.speaking
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
                            backgroundColor: const Color(0xFFDC2626),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 18),
                          ),
                          onPressed: _closeOverlay,
                          icon: const Icon(Icons.call_end_rounded),
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
