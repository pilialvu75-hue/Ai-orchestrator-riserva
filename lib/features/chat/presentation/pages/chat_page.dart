import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/services.dart';

// Importazione pulita dei componenti satelliti (senza chat_app_bar che ora è interna)
import 'package:ai_orchestrator/presentation/chat/components/chat_conversation.dart';
import 'package:ai_orchestrator/presentation/chat/components/high_performance_chat_list.dart';
import 'package:ai_orchestrator/presentation/chat/components/runtime_metrics_widget.dart';
import 'package:ai_orchestrator/presentation/chat/components/chat_input_section.dart';
import 'package:ai_orchestrator/presentation/chat/components/debug_lab_overlay.dart';

// Servizi infrastrutturali core
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_diagnostics_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/orchestrator_state_engine.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_event.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_state.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;

const String _kDefaultSessionId = 'default';
const Duration _kRuntimeStatePollInterval = Duration(seconds: 2);

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  static const _mlcNativeChannel = MethodChannel('com.aiorchestrator/mlc_native');
  static const Duration _uiDeadlockTimeout = Duration(seconds: 15);
  final _scrollController = ScrollController();
  
  late final LocalRuntimeDiagnosticsService _runtimeDiagnostics;
  late final AiRuntimeSettingsService _runtimeSettings;
  late final VoiceEngine _voiceEngine;
  
  LocalRuntimeState _runtimeState = const LocalRuntimeState();
  Timer? _runtimeStateSyncTimer;
  int? _runtimeStateSignature;
  Timer? _uiDeadlockTimer;
  DateTime? _uiSendBeganAt;
  bool _uiStreamStarted = false;
  
  bool _voiceEngineActive = false;
  bool _gpuAccelerationActive = false;
  String _gpuBackend = 'cpu';
  String _runtimeModeName = 'hybrid';

  bool _showMetrics = false;
  bool _debugLabOpen = false;
  double _textScale = 1.0;
  double _assistantTextSize = 14.0;
  int _secretClickCount = 0;

  @override
  void initState() {
    super.initState();
    context.read<OrchestratorStateEngine>().add(const LoadMessagesEvent(sessionId: _kDefaultSessionId));
    
    _runtimeDiagnostics = di.sl<LocalRuntimeDiagnosticsService>();
    _runtimeSettings = di.sl<AiRuntimeSettingsService>();
    _voiceEngine = di.sl<VoiceEngine>();
    
    _runtimeState = _runtimeDiagnostics.monitor.state;
    _runtimeStateSignature = _signatureForRuntimeState(_runtimeState);
    
    WidgetsBinding.instance.addObserver(this);
    _startRuntimeStateSync();
    unawaited(_refreshRuntimeIndicators());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startRuntimeStateSync();
    } else {
      _stopRuntimeStateSync();
    }
  }

  void _syncRuntimeStateFromMonitor() {
    if (!mounted) return;
    final state = _runtimeDiagnostics.monitor.state;
    final signature = _signatureForRuntimeState(state);
    if (signature == _runtimeStateSignature) return;
    setState(() {
      _runtimeState = state;
      _runtimeStateSignature = signature;
    });
    unawaited(_refreshRuntimeIndicators());
  }

  int _signatureForRuntimeState(LocalRuntimeState state) {
    return Object.hash(state.status, state.message, state.tokensGenerated, state.elapsed, state.startedAt);
  }

  void _startRuntimeStateSync() {
    if (!mounted) return;
    if (_runtimeStateSyncTimer?.isActive == true) return;
    _runtimeStateSyncTimer = Timer.periodic(_kRuntimeStatePollInterval, (timer) => _syncRuntimeStateFromMonitor());
  }

  void _stopRuntimeStateSync() {
    _runtimeStateSyncTimer?.cancel();
    _runtimeStateSyncTimer = null;
  }

  Future<void> _refreshRuntimeIndicators() async {
    final runtimeMode = await _runtimeSettings.loadRuntimeMode();
    final voiceStatus = await _voiceEngine.inspect();
    var gpuActive = false;
    var gpuBackend = 'cpu';
    try {
      final nativeAvailable = await _mlcNativeChannel.invokeMethod<bool>('isMlcNativeAvailable');
      final backend = await _mlcNativeChannel.invokeMethod<String>('getMlcBackend');
      gpuBackend = (backend ?? 'cpu').trim();
      final normalizedBackend = gpuBackend.toLowerCase();
      gpuActive = nativeAvailable == true &&
          normalizedBackend.isNotEmpty &&
          normalizedBackend != 'cpu' &&
          normalizedBackend != 'fallback-llama';
    } on PlatformException {
      gpuActive = false;
      gpuBackend = 'unavailable';
    } on MissingPluginException {
      gpuActive = false;
      gpuBackend = 'unavailable';
    }
    if (!mounted) return;
    setState(() {
      _runtimeModeName = runtimeMode.name;
      _voiceEngineActive = voiceStatus.offlineAsrAvailable && voiceStatus.readyForInput;
      _gpuAccelerationActive = gpuActive;
      _gpuBackend = gpuBackend;
    });
  }

  void _onSend(String text) {
    debugPrint('[CHAT_UI] [FORENSIC_BEFORE_ONSEND] chars=${text.length}');
    _uiSendBeganAt = DateTime.now();
    _uiStreamStarted = false;
    _startUiDeadlockGuard();
    
    context.read<OrchestratorStateEngine>().add(SendMessageEvent(
          sessionId: _kDefaultSessionId,
          userPrompt: text,
          attachments: const [],
        ));
  }

  bool _isRuntimeInferencing() {
    return _runtimeState.status == LocalRuntimeStatus.inferencing ||
        _runtimeState.status == LocalRuntimeStatus.streaming;
  }

  void _startUiDeadlockGuard() {
    _cancelUiDeadlockGuard();
    _uiDeadlockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final startedAt = _uiSendBeganAt;
      if (startedAt == null || !mounted || _uiStreamStarted) return;
      final chatState = context.read<OrchestratorStateEngine>().state;
      final waiting = chatState is ChatSending;
      final elapsed = DateTime.now().difference(startedAt);
      if (waiting && !_isRuntimeInferencing() && elapsed > _uiDeadlockTimeout) {
        context.read<OrchestratorStateEngine>().add(
              const RecoverFromStuckUiEvent(
                sessionId: _kDefaultSessionId,
                runtimeMessage: 'Local runtime stalled before first token. Request cancelled and UI recovered.',
              ),
            );
        _cancelUiDeadlockGuard();
      }
    });
  }

  void _cancelUiDeadlockGuard() {
    _uiDeadlockTimer?.cancel();
    _uiDeadlockTimer = null;
    _uiSendBeganAt = null;
    _uiStreamStarted = false;
  }

  void _handleSecretPatternClick() {
    setState(() {
      _secretClickCount++;
      if (_secretClickCount >= 7) {
        _secretClickCount = 0;
        _debugLabOpen = !_debugLabOpen;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF131314),
      body: Stack(
        children: [
          BlocBuilder<OrchestratorStateEngine, ChatState>(
            builder: (context, chatState) {
              final List<dynamic> currentMessages = (chatState as dynamic).messages ?? const [];
              
              return ChatConversation(
                textScale: _textScale,
                title: 'Phi-3.5-mini',
                onTitlePressed: _handleSecretPatternClick,
                onSettingsPressed: () {
                  setState(() {
                    _showMetrics = !_showMetrics;
                  });
                },
                chatList: HighPerformanceChatList(
                  messages: currentMessages,
                  textSize: _assistantTextSize,
                ),
                inputSection: ChatInputSection(
                  onSend: _onSend,
                  onVoicePressed: () {
                    showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      builder: (context) => const SizedBox(
                        height: 350,
                        child: Center(child: Text('Voice Session Activating...')),
                      ),
                    );
                  },
                  isSending: chatState is ChatSending,
                ),
              );
            },
          ),
          if (_showMetrics)
            RuntimeMetricsWidget(
              monitorState: _runtimeState,
              voiceEngineActive: _voiceEngineActive,
              gpuAccelerationActive: _gpuAccelerationActive,
              gpuBackend: _gpuBackend,
              runtimeModeName: _runtimeModeName,
              onClose: () => setState(() => _showMetrics = false),
            ),
          if (_debugLabOpen)
            DebugLabOverlay(
              onToggleMetrics: () => setState(() {
                _showMetrics = !_showMetrics;
                _debugLabOpen = false;
              }),
              onTextScaleChanged: (scale) => setState(() => _textScale = scale),
              onFontSizeChanged: (size) => setState(() => _assistantTextSize = size),
              currentTextScale: _textScale,
              currentFontSize: _assistantTextSize,
              onClose: () => setState(() => _debugLabOpen = false),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopRuntimeStateSync();
    _cancelUiDeadlockGuard();
    _scrollController.dispose();
    super.dispose();
  }
}
