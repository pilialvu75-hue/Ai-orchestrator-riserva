import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/services.dart';
import 'package:ai_orchestrator/core/voice/voice_output_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_message.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_diagnostics_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/core/voice/voice_loop_manager.dart';
import 'package:ai_orchestrator/core/voice/voice_model_downloader.dart';
import 'package:ai_orchestrator/core/voice/sherpa_onnx_voice_engine.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_bloc.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_event.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_state.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/settings_page.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/orchestrator_state_engine.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_event.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_state.dart';
import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_bubble.dart';
import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_input_bar.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;

const String _kDefaultSessionId = 'default';
const int _kAssistantTtsRecencyThresholdSeconds = 10;

// Width threshold above which a persistent sidebar replaces the Drawer.
const double _kSidebarBreakpoint = 720;

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const _mlcNativeChannel = MethodChannel('com.aiorchestrator/mlc_native');
  static const Duration _uiDeadlockTimeout = Duration(seconds: 15);
  final _scrollController = ScrollController();
  late final LocalRuntimeDiagnosticsService _runtimeDiagnostics;
  late final AiRuntimeSettingsService _runtimeSettings;
  late final VoiceEngine _voiceEngine;
  late final VoiceLoopManager _voiceLoopManager;
  late final SherpaOnnxVoiceEngine _voiceLoopEngine;
  late final VoiceModelDownloader _voiceModelDownloader;
  LocalRuntimeState _runtimeState = const LocalRuntimeState();
  Timer? _uiDeadlockTimer;
  DateTime? _uiSendBeganAt;
  bool _uiStreamStarted = false;
  bool _voiceEngineActive = false;
  bool _gpuAccelerationActive = false;
  String _gpuBackend = 'cpu';
  String _runtimeModeName = 'hybrid';

  @override
  void initState() {
    super.initState();
    context
        .read<OrchestratorStateEngine>()
        .add(const LoadMessagesEvent(sessionId: _kDefaultSessionId));
    _runtimeDiagnostics = di.sl<LocalRuntimeDiagnosticsService>();
    _runtimeSettings = di.sl<AiRuntimeSettingsService>();
    _voiceEngine = di.sl<VoiceEngine>();
    _voiceLoopManager = di.sl<VoiceLoopManager>();
    _voiceLoopEngine = di.sl<SherpaOnnxVoiceEngine>();
    _voiceModelDownloader = di.sl<VoiceModelDownloader>();
    _runtimeState = _runtimeDiagnostics.monitor.state;
    _runtimeDiagnostics.monitor.addListener(_handleRuntimeStateChanged);
    unawaited(_refreshRuntimeIndicators());
    final modelBloc = context.read<ModelDownloadBloc>();
    if (modelBloc.state is ModelDownloadInitial) {
      modelBloc.add(const LoadAvailableModels());
    }
  }

  void _handleRuntimeStateChanged(LocalRuntimeState state) {
    if (!mounted) return;
    setState(() => _runtimeState = state);
    unawaited(_refreshRuntimeIndicators());
  }

  Future<void> _refreshRuntimeIndicators() async {
    final runtimeMode = await _runtimeSettings.loadRuntimeMode();
    final voiceStatus = await _voiceEngine.inspect();
    var gpuActive = false;
    var gpuBackend = 'cpu';
    try {
      final nativeAvailable =
          await _mlcNativeChannel.invokeMethod<bool>('isMlcNativeAvailable');
      final backend =
          await _mlcNativeChannel.invokeMethod<String>('getMlcBackend');
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
      _voiceEngineActive =
          voiceStatus.offlineAsrAvailable && voiceStatus.readyForInput;
      _gpuAccelerationActive = gpuActive;
      _gpuBackend = gpuBackend;
    });
  }

  @override
  void dispose() {
    _cancelUiDeadlockGuard();
    _runtimeDiagnostics.monitor.removeListener(_handleRuntimeStateChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onSend(String text, List<ChatAttachment> attachments) {
    // Log di ingresso forense per mappare lo scenario di tracciamento
    _uiLog('[FORENSIC_BEFORE_ONSEND] chars=${text.length} attachments=${attachments.length}');

    _uiSendBeganAt = DateTime.now();
    _uiStreamStarted = false;
    _startUiDeadlockGuard();
    _uiLog(
      '[UI_SEND] session=$_kDefaultSessionId page=${hashCode.toRadixString(16)} chars=${text.length} attachments=${attachments.length}',
    );
    _uiLog('[UI_SEND_BEGIN] session=$_kDefaultSessionId chars=${text.length} attachments=${attachments.length}');
    
    context.read<OrchestratorStateEngine>().add(SendMessageEvent(
          sessionId: _kDefaultSessionId,
          userPrompt: text,
          attachments: attachments,
        ));

    // Log di uscita forense per verificare se l'esecuzione supera l'aggiunta all'Engine
    _uiLog('[FORENSIC_AFTER_ONSEND]');
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
        _uiLog('[UI_WAITING_STUCK] session=$_kDefaultSessionId elapsed_ms=${elapsed.inMilliseconds} runtime=${_runtimeState.status.name}');
        _uiLog('[inference_loop_detected] session=$_kDefaultSessionId waiting=true no_token=true runtime_inferencing=false');
        _uiLog('[UI_SEND_CANCEL] session=$_kDefaultSessionId reason=deadlock_breaker');
        context.read<OrchestratorStateEngine>().add(
              const RecoverFromStuckUiEvent(
                sessionId: _kDefaultSessionId,
                runtimeMessage:
                    'Local runtime stalled before first token. Request cancelled and UI recovered.',
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

  void _handleOrchestratorState(ChatState state) {
    if (_uiSendBeganAt == null) return;
    if (state is ChatSending) {
      final hasAssistantToken = state.messages.any(
        (message) => message.role == 'assistant' && message.content.trim().isNotEmpty,
      );
      if (hasAssistantToken && !_uiStreamStarted) {
        _uiStreamStarted = true;
        _uiLog('[UI_STREAM_BEGIN] session=$_kDefaultSessionId');
      }
      return;
    }
    _uiLog('[UI_STREAM_END] session=$_kDefaultSessionId state=${state.runtimeType}');
    _cancelUiDeadlockGuard();
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BlocProvider.value(
          value: context.read<ModelDownloadBloc>(),
          child: const SettingsPage(),
        ),
      ),
    );
  }

  Future<void> _openLiveVoiceSession() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.76),
      isDismissible: false,
      enableDrag: false,
      builder: (_) => _LiveVoiceOverlay(
        voiceLoopManager: _voiceLoopManager,
        voiceEngine: _voiceLoopEngine,
        voiceModelDownloader: _voiceModelDownloader,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<ModelDownloadBloc, ModelDownloadState>(
          listener: (context, state) {
            final l10n = context.l10n;
            if (state is ModelDownloadError) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Models: ${state.message}'),
                  backgroundColor: Theme.of(context).colorScheme.error,
                  action: SnackBarAction(
                    label: l10n.t('settings'),
                    textColor: Colors.white,
                    onPressed: _openSettings,
                  ),
                ),
              );
            }
          },
        ),
        BlocListener<OrchestratorStateEngine, ChatState>(
          listener: (context, state) => _handleOrchestratorState(state),
        ),
      ],
      child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= _kSidebarBreakpoint;
            return isWide
                ? _WideLayout(
                    scrollController: _scrollController,
                    onSend: _onSend,
                    onSettings: _openSettings,
                    scrollToBottom: _scrollToBottom,
                    runtimeState: _runtimeState,
                    voiceEngineActive: _voiceEngineActive,
                    gpuAccelerationActive: _gpuAccelerationActive,
                    gpuBackend: _gpuBackend,
                    runtimeModeName: _runtimeModeName,
                    onStartLiveSession: _openLiveVoiceSession,
                    liveSessionEnabled: !_voiceLoopManager.isSessionActive,
                  )
                : _NarrowLayout(
                    scrollController: _scrollController,
                    onSend: _onSend,
                    onSettings: _openSettings,
                    scrollToBottom: _scrollToBottom,
                    runtimeState: _runtimeState,
                    voiceEngineActive: _voiceEngineActive,
                    gpuAccelerationActive: _gpuAccelerationActive,
                    gpuBackend: _gpuBackend,
                    runtimeModeName: _runtimeModeName,
                    onStartLiveSession: _openLiveVoiceSession,
                    liveSessionEnabled: !_voiceLoopManager.isSessionActive,
                  );
          }),
    );
  }

  static void _uiLog(String message) {
    debugPrint('[CHAT_UI] $message');
  }
}

// ── Narrow (mobile) layout — drawer ──────────────────────────────────────────

class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout({
    required this.scrollController,
    required this.onSend,
    required this.onSettings,
    required this.scrollToBottom,
    required this.runtimeState,
    required this.voiceEngineActive,
    required this.gpuAccelerationActive,
    required this.gpuBackend,
    required this.runtimeModeName,
    required this.onStartLiveSession,
    required this.liveSessionEnabled,
  });

  final ScrollController scrollController;
  final void Function(String text, List<ChatAttachment> attachments) onSend;
  final VoidCallback onSettings;
  final VoidCallback scrollToBottom;
  final LocalRuntimeState runtimeState;
  final bool voiceEngineActive;
  final bool gpuAccelerationActive;
  final String gpuBackend;
  final String runtimeModeName;
  final VoidCallback onStartLiveSession;
  final bool liveSessionEnabled;

  @override
  Widget build(BuildContext context) {
    return _ChatBody(
      scrollController: scrollController,
      onSend: onSend,
      onSettings: onSettings,
      scrollToBottom: scrollToBottom,
      runtimeState: runtimeState,
      voiceEngineActive: voiceEngineActive,
      gpuAccelerationActive: gpuAccelerationActive,
      gpuBackend: gpuBackend,
      runtimeModeName: runtimeModeName,
      onStartLiveSession: onStartLiveSession,
      liveSessionEnabled: liveSessionEnabled,
    );
  }
}

// ── Wide (tablet/desktop) layout — persistent sidebar ────────────────────────

class _WideLayout extends StatelessWidget {
  const _WideLayout({
    required this.scrollController,
    required this.onSend,
    required this.onSettings,
    required this.scrollToBottom,
    required this.runtimeState,
    required this.voiceEngineActive,
    required this.gpuAccelerationActive,
    required this.gpuBackend,
    required this.runtimeModeName,
    required this.onStartLiveSession,
    required this.liveSessionEnabled,
  });

  final ScrollController scrollController;
  final void Function(String text, List<ChatAttachment> attachments) onSend;
  final VoidCallback onSettings;
  final VoidCallback scrollToBottom;
  final LocalRuntimeState runtimeState;
  final bool voiceEngineActive;
  final bool gpuAccelerationActive;
  final String gpuBackend;
  final String runtimeModeName;
  final VoidCallback onStartLiveSession;
  final bool liveSessionEnabled;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        // Persistent sidebar
        SizedBox(
          width: 220,
          child: Container(
            color: const Color(0xFF1A1A1A),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                    child: Text(
                      l10n.t('ai_orchestrator'),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  const Divider(color: Colors.white12),
                  _SidebarTile(
                    icon: Icons.chat_bubble_outline_rounded,
                    label: l10n.t('chat'),
                    onTap: () {},
                  ),
                  const Spacer(),
                  const Divider(color: Colors.white12),
                  _SidebarTile(
                    icon: Icons.settings_outlined,
                    label: l10n.t('settings'),
                    onTap: onSettings,
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: _ChatBody(
            scrollController: scrollController,
            onSend: onSend,
             onSettings: onSettings,
             scrollToBottom: scrollToBottom,
             runtimeState: runtimeState,
             voiceEngineActive: voiceEngineActive,
             gpuAccelerationActive: gpuAccelerationActive,
             gpuBackend: gpuBackend,
             runtimeModeName: runtimeModeName,
             onStartLiveSession: onStartLiveSession,
             liveSessionEnabled: liveSessionEnabled,
           ),
        ),
      ],
    );
  }
}

class _ChatBody extends StatefulWidget {
  const _ChatBody({
    required this.scrollController,
    required this.onSend,
    required this.onSettings,
    required this.scrollToBottom,
    required this.runtimeState,
    required this.voiceEngineActive,
    required this.gpuAccelerationActive,
    required this.gpuBackend,
    required this.runtimeModeName,
    required this.onStartLiveSession,
    required this.liveSessionEnabled,
  });

  final ScrollController scrollController;
  final void Function(String text, List<ChatAttachment> attachments) onSend;
  final VoidCallback onSettings;
  final VoidCallback scrollToBottom;
  final LocalRuntimeState runtimeState;
  final bool voiceEngineActive;
  final bool gpuAccelerationActive;
  final String gpuBackend;
  final String runtimeModeName;
  final VoidCallback onStartLiveSession;
  final bool liveSessionEnabled;

  @override
  State<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<_ChatBody> {
  String? _lastSpokenAssistantMessageId;

  Future<void> _speakAssistantResponse(String text) async {
    try {
      await di.sl<VoiceOutputService>().speak(text);
    } catch (error) {
      debugPrint('TTS playback failed: $error');
    }
  }

  String? _runtimeMessageForState(ChatState state) {
    if (state is ChatLoaded) return state.runtimeMessage;
    if (state is ChatSending) return state.runtimeMessage;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<OrchestratorStateEngine, ChatState>(
      listener: (context, state) {
        if (state is ChatLoaded || state is ChatSending) {
          widget.scrollToBottom();
        }
        final runtimeMessage = _runtimeMessageForState(state);
        if (runtimeMessage != null && runtimeMessage.trim().isNotEmpty) {
          final l10n = context.l10n;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(runtimeMessage),
              backgroundColor: Theme.of(context).colorScheme.error,
              action: (state is ChatLoaded && state.suggestOpeningSettings)
                  ? SnackBarAction(
                      label: l10n.t('settings'),
                      textColor: Colors.white,
                      onPressed: widget.onSettings,
                    )
                  : null,
            ),
          );
        }

        if (state is ChatLoaded && state.messages.isNotEmpty) {
          final latest = state.messages.last;
          final isRecent = DateTime.now()
                  .difference(DateTime.fromMillisecondsSinceEpoch(latest.timestamp))
                  .inSeconds <
              _kAssistantTtsRecencyThresholdSeconds;
          if (isRecent &&
              latest.role == 'assistant' &&
              latest.content.trim().isNotEmpty &&
              latest.id != _lastSpokenAssistantMessageId) {
            _lastSpokenAssistantMessageId = latest.id;
            // Fire-and-forget to keep UI/inference flow non-blocking.
            unawaited(_speakAssistantResponse(latest.content));
          }
        }
      },
      builder: (context, state) {
        if (state is ChatInitial || state is ChatLoading) {
          return const Center(
              child: CircularProgressIndicator(color: Color(0xFF8AB4F8)));
        }
        if (state is ChatError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(state.message,
                  style: const TextStyle(color: Colors.redAccent),
                  textAlign: TextAlign.center),
            ),
          );
        }

        final List<ChatMessage> messages = state is ChatLoaded
            ? state.messages
            : (state is ChatSending ? state.messages : const <ChatMessage>[]);
        final isLoading = state is ChatSending;

        return Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          const Color(0xFF101526).withValues(alpha: 0.65),
                          const Color(0xFF11192B).withValues(alpha: 0.9),
                          const Color(0xFF0B0F17),
                        ],
                      ),
                    ),
                    child: messages.isEmpty
                        ? _buildEmptyState(context)
                        : _HighPerformanceChatList(
                            controller: widget.scrollController,
                            messages: messages,
                          ),
                  ),
                  Positioned(
                    top: 10,
                    right: 10,
                     child: IgnorePointer(
                      child: _RuntimeDebugOverlay(
                        runtimeState: widget.runtimeState,
                        voiceEngineActive: widget.voiceEngineActive,
                        gpuAccelerationActive: widget.gpuAccelerationActive,
                        gpuBackend: widget.gpuBackend,
                        runtimeModeName: widget.runtimeModeName,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ChatInputBar(
              onSend: widget.onSend,
              isLoading: isLoading,
              onStartLiveSession: widget.onStartLiveSession,
              liveSessionEnabled: widget.liveSessionEnabled,
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 86,
            height: 86,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  const Color(0xFF8AB4F8).withValues(alpha: 0.28),
                  Colors.transparent,
                ],
              ),
              border: Border.all(color: const Color(0xFF8AB4F8).withValues(alpha: 0.14)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x3315B6FF),
                  blurRadius: 26,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(
              Icons.auto_awesome,
              color: Color(0xFF8AB4F8),
              size: 42,
            ),
          ),
          const SizedBox(height: 16),
          Text(l10n.t('ai_orchestrator'),
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 22,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Text(l10n.t('start_conversation'),
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.35), fontSize: 14)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF151A29).withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Text(
              l10n.t('chat_surface_tagline'),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.52),
                fontSize: 12,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HighPerformanceChatList extends StatelessWidget {
  const _HighPerformanceChatList({
    required this.controller,
    required this.messages,
  });

  final ScrollController controller;
  final List<ChatMessage> messages;

  @override
  Widget build(BuildContext context) {
    return ListView.custom(
      controller: controller,
      cacheExtent: 1200,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.symmetric(vertical: 12),
      childrenDelegate: SliverChildBuilderDelegate(
        (context, index) {
          final message = messages[index];
          return RepaintBoundary(
            child: _AnimatedBubble(
              key: ValueKey(message.id),
              child: ChatBubble(message: message),
            ),
          );
        },
        childCount: messages.length,
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
        addSemanticIndexes: false,
      ),
    );
  }
}

enum _LiveVoiceUiState { listening, thinking, speaking, idle }

class _LiveVoiceOverlay extends StatefulWidget {
  const _LiveVoiceOverlay({
    required this.voiceLoopManager,
    required this.voiceEngine,
    required this.voiceModelDownloader,
  });

  final VoiceLoopManager voiceLoopManager;
  final VoiceEngine voiceEngine;
  final VoiceModelDownloader voiceModelDownloader;

  @override
  State<_LiveVoiceOverlay> createState() => _LiveVoiceOverlayState();
}

class _LiveVoiceOverlayState extends State<_LiveVoiceOverlay> {
  final ValueNotifier<_LiveVoiceUiState> _uiState =
      ValueNotifier<_LiveVoiceUiState>(_LiveVoiceUiState.thinking);
  Timer? _stateTicker;
  bool _closing = false;
  String? _error;
  bool _isDownloadingModels = false;
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
    return (!status.isVoiceDownloaded && !status.readyForInput) ||
        details.contains('modelli mancanti') ||
        details.contains('risorse vocali mancanti');
  }

  Future<void> _ensureLiveModeStartupReady(VoiceEngineStatus status) async {
    RuntimeEventLog.instance.emit(
      '[VOICE_LIVE_ASSET_CHECK_BEGIN] validating voice assets before Live Mode startup',
    );
    if (!status.readyForInput && !status.readyForOutput) {
      const message =
          'I modelli vocali richiesti non sono disponibili. Completa di nuovo il download dei modelli vocali prima di avviare Live Mode.';
      RuntimeEventLog.instance.emit('[VOICE_LIVE_ASSET_CHECK_FAIL] $message');
      throw const VoiceAssetException(message);
    }

    if (!status.readyForInput) {
      final detail = (status.details ?? '').trim();
      final message = detail.isEmpty
          ? 'Live Mode richiede almeno STT valido e accesso al microfono. Verifica il download dei modelli STT e i permessi microfono, poi riprova.'
          : 'Live Mode non può avviarsi: $detail';
      RuntimeEventLog.instance.emit('[VOICE_LIVE_ASSET_CHECK_FAIL] $message');
      throw VoiceAssetException(message);
    }

    if (status.readyForInput && status.readyForOutput) {
      await widget.voiceModelDownloader.validateDownloadedAssets();
    } else {
      RuntimeEventLog.instance.emit(
        '[VOICE_LIVE_ASSET_CHECK_PARTIAL] Live Mode in partial readiness: '
        'readyForInput=${status.readyForInput} readyForOutput=${status.readyForOutput}',
      );
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

  @override
  void dispose() {
    _stateTicker?.cancel();
    _uiState.dispose();
    unawaited(widget.voiceLoopManager.stopLiveSession());
    super.dispose();
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
                            backgroundColor: Colors.white.withValues(alpha: 0.14),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Color(0xFF8AB4F8),
                            ),
                          ),
                        ),
                        if ((_error ?? '').trim().isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0xFFFF8A80),
                              fontSize: 13,
                            ),
                          ),
                        ],
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
                      if ((_error ?? '').trim().isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFFFF8A80),
                            fontSize: 13,
                          ),
                        ),
                      ],
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

class _RuntimeDebugOverlay extends StatefulWidget {
  const _RuntimeDebugOverlay({
    required this.runtimeState,
    required this.voiceEngineActive,
    required this.gpuAccelerationActive,
    required this.gpuBackend,
    required this.runtimeModeName,
  });

  final LocalRuntimeState runtimeState;
  final bool voiceEngineActive;
  final bool gpuAccelerationActive;
  final String gpuBackend;
  final String runtimeModeName;

  @override
  State<_RuntimeDebugOverlay> createState() => _RuntimeDebugOverlayState();
}

class _RuntimeDebugOverlayState extends State<_RuntimeDebugOverlay> {
  @override
  void initState() {
    super.initState();
    _scheduleTick();
  }

  void _scheduleTick() {
    Future<void>.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() {});
      _scheduleTick();
    });
  }

  String _title(BuildContext context) {
    final l10n = context.l10n;
    final message = (widget.runtimeState.message ?? '').toLowerCase();
    switch (widget.runtimeState.status) {
      case LocalRuntimeStatus.uninitialized:
        return l10n.t('runtime_idle');
      case LocalRuntimeStatus.loading:
        return l10n.t('runtime_loading');
      case LocalRuntimeStatus.runtimeUnavailable:
        return l10n.t('runtime_unverified');
      case LocalRuntimeStatus.tokenizing:
        return l10n.t('runtime_tokenizing');
      case LocalRuntimeStatus.inferencing:
        return l10n.t('runtime_generating');
      case LocalRuntimeStatus.streaming:
        return l10n.t('runtime_streaming');
      case LocalRuntimeStatus.completed:
        return l10n.t('runtime_completed');
      case LocalRuntimeStatus.timedOut:
        return l10n.t('runtime_timed_out');
      case LocalRuntimeStatus.stalled:
        return l10n.t('runtime_stalled');
      case LocalRuntimeStatus.ready:
        return l10n.t('runtime_ready');
      case LocalRuntimeStatus.ffiMissing:
      case LocalRuntimeStatus.modelMissing:
      case LocalRuntimeStatus.failed:
        if (message.startsWith('out of memory') || message.contains('out of memory')) {
          return l10n.t('runtime_error');
        }
        return l10n.t('runtime_error');
    }
  }

  Color get _color {
    switch (widget.runtimeState.status) {
      case LocalRuntimeStatus.uninitialized:
        return const Color(0xFF6B7280);
      case LocalRuntimeStatus.ready:
        return const Color(0xFF8AB4F8);
      case LocalRuntimeStatus.runtimeUnavailable:
        return const Color(0xFFF9A826);
      case LocalRuntimeStatus.completed:
        return const Color(0xFF4ADE80);
      case LocalRuntimeStatus.streaming:
        return const Color(0xFF7DD3FC);
      case LocalRuntimeStatus.inferencing:
      case LocalRuntimeStatus.tokenizing:
      case LocalRuntimeStatus.loading:
        return const Color(0xFFF9A826);
      case LocalRuntimeStatus.timedOut:
        return const Color(0xFFFFB74D);
      case LocalRuntimeStatus.stalled:
      case LocalRuntimeStatus.ffiMissing:
      case LocalRuntimeStatus.modelMissing:
      case LocalRuntimeStatus.failed:
        return const Color(0xFFFF8A80);
    }
  }

  Duration get _displayElapsed {
    final state = widget.runtimeState;
    if (state.startedAt != null &&
        (state.status == LocalRuntimeStatus.inferencing ||
            state.status == LocalRuntimeStatus.streaming ||
            state.status == LocalRuntimeStatus.tokenizing)) {
      return DateTime.now().difference(state.startedAt!);
    }
    return state.elapsed;
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
    final elapsed = _displayElapsed;
    final l10n = context.l10n;
    return Container(
      width: 180,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F131A).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.14),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _title(context),
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if ((widget.runtimeState.message ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              widget.runtimeState.message!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '${l10n.t('tokens')} ${widget.runtimeState.tokensGenerated}',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            '${l10n.t('time')} ${elapsed.inSeconds}s',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 8),
          _statusPill(
            icon: Icons.memory_rounded,
            label: l10n.t('local_runtime'),
            active: widget.runtimeState.status != LocalRuntimeStatus.ffiMissing &&
                widget.runtimeState.status != LocalRuntimeStatus.runtimeUnavailable &&
                widget.runtimeState.status != LocalRuntimeStatus.modelMissing &&
                widget.runtimeState.status != LocalRuntimeStatus.failed,
          ),
          const SizedBox(height: 4),
          _statusPill(
            icon: Icons.mic_rounded,
            label: l10n.t('voice_engine'),
            active: widget.voiceEngineActive,
          ),
          const SizedBox(height: 4),
          Text(
            '${l10n.t('mode')}: ${widget.runtimeModeName}',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 4),
          _statusPill(
            icon: Icons.developer_board_rounded,
            label: 'GPU ${widget.gpuBackend}',
            active: widget.gpuAccelerationActive,
          ),
        ],
      ),
    );
  }

  Widget _statusPill({
    required IconData icon,
    required String label,
    required bool active,
  }) {
    final color = active ? const Color(0xFF4ADE80) : const Color(0xFFFF8A80);
    return Row(
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '$label ${active ? 'ON' : 'OFF'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

// Lightweight fade-in animation wrapping each chat bubble.
class _AnimatedBubble extends StatefulWidget {
  const _AnimatedBubble({super.key, required this.child});
  final Widget child;

  @override
  State<_AnimatedBubble> createState() => _AnimatedBubbleState();
}

class _AnimatedBubbleState extends State<_AnimatedBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 280));
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
            begin: const Offset(0, 0.06), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

class _SidebarTile extends StatelessWidget {
  const _SidebarTile(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: const Color(0xFF8AB4F8), size: 20),
              const SizedBox(width: 14),
              Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }
}
