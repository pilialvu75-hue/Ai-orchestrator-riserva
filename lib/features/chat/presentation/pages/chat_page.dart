// chat_page.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ai_orchestrator/core/voice/voice_output_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/chat_ui_preferences_service.dart';
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
import 'package:ai_orchestrator/features/chat/presentation/debug/debug_lab_controller.dart';
import 'package:ai_orchestrator/features/chat/presentation/debug/debug_overlay.dart';
import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_input_bar.dart';
import 'package:ai_orchestrator/presentation/chat/components/high_performance_chat_list.dart';
import 'package:ai_orchestrator/presentation/chat/components/live_voice_overlay.dart';
import 'package:ai_orchestrator/presentation/chat/components/runtime_metrics_widget.dart';
import 'package:ai_orchestrator/presentation/chat/controllers/chat_deadlock_controller.dart';
import 'package:ai_orchestrator/presentation/chat/controllers/execution_hardware_controller.dart';
import 'package:ai_orchestrator/presentation/chat/controllers/runtime_state_controller.dart';
import 'package:ai_orchestrator/presentation/chat/controllers/system_indicators_controller.dart';
import 'package:ai_orchestrator/presentation/chat/view_models/chat_appearance_view_model.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;

const String _kDefaultSessionId = 'default';
const int _kAssistantTtsRecencyThresholdSeconds = 10;
const Duration _kRuntimeStatePollInterval = Duration(seconds: 2);

// Width threshold above which a persistent sidebar replaces the Drawer.
const double _kSidebarBreakpoint = 720;

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  static const Duration _uiDeadlockTimeout = Duration(seconds: 15);
  final _scrollController = ScrollController();
  final List<ChatMessage> _debugLabMessages = <ChatMessage>[];

  late final LocalRuntimeDiagnosticsService _runtimeDiagnostics;
  late final AiRuntimeSettingsService _runtimeSettings;
  late final VoiceEngine _voiceEngine;
  late final VoiceLoopManager _voiceLoopManager;
  late final SherpaOnnxVoiceEngine _voiceLoopEngine;
  late final VoiceModelDownloader _voiceModelDownloader;
  late final RuntimeStateController _runtimeStateController;
  late final ExecutionHardwareController _hardwareController;
  late final SystemIndicatorsController _systemIndicatorsController;
  late final ChatDeadlockController _deadlockController;
  late final ChatAppearanceViewModel _appearanceViewModel;

  LocalRuntimeState get _runtimeState => _runtimeStateController.value.state;
  HardwareSnapshot get _hardwareSnapshot => _hardwareController.value;
  SystemIndicatorsSnapshot get _systemIndicatorsSnapshot =>
      _systemIndicatorsController.value;

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
    _runtimeStateController = RuntimeStateController(
      diagnostics: _runtimeDiagnostics,
    );
    _hardwareController = ExecutionHardwareController();
    _systemIndicatorsController = SystemIndicatorsController(
      runtimeSettings: _runtimeSettings,
      voiceEngine: _voiceEngine,
    );
    _deadlockController = ChatDeadlockController(
      timeout: _uiDeadlockTimeout,
    );
    _appearanceViewModel = ChatAppearanceViewModel();
    _runtimeStateController.addListener(_handleRuntimeStateChanged);
    _hardwareController.addListener(_handlePresentationStateChanged);
    _systemIndicatorsController.addListener(_handlePresentationStateChanged);
    _appearanceViewModel.addListener(_handlePresentationStateChanged);
    WidgetsBinding.instance.addObserver(this);
    _runtimeStateController.startMonitoring(_kRuntimeStatePollInterval);
    unawaited(_refreshPresentationIndicators());
    final modelBloc = context.read<ModelDownloadBloc>();
    if (modelBloc.state is ModelDownloadInitial) {
      modelBloc.add(const LoadAvailableModels());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _runtimeStateController.startMonitoring(_kRuntimeStatePollInterval);
      unawaited(_refreshPresentationIndicators());
    } else {
      _runtimeStateController.stopMonitoring();
    }
  }

  void _handlePresentationStateChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _handleRuntimeStateChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(_refreshPresentationIndicators());
  }

  Future<void> _refreshPresentationIndicators() async {
    await Future.wait<void>([
      _hardwareController.refreshHardwareStatus(),
      _systemIndicatorsController.refreshIndicators(),
    ]);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _runtimeStateController.removeListener(_handleRuntimeStateChanged);
    _hardwareController.removeListener(_handlePresentationStateChanged);
    _systemIndicatorsController.removeListener(_handlePresentationStateChanged);
    _appearanceViewModel.removeListener(_handlePresentationStateChanged);
    _runtimeStateController.dispose();
    _hardwareController.dispose();
    _systemIndicatorsController.dispose();
    _deadlockController.dispose();
    _appearanceViewModel.dispose();
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
    _uiLog('[FORENSIC_BEFORE_ONSEND] chars=${text.length} attachments=${attachments.length}');
    _deadlockController.handleSendBegan();
    _deadlockController.startGuard(
      isSending: () => context.read<OrchestratorStateEngine>().state is ChatSending,
      isInferencing: _runtimeStateController.isInferencing,
      onDeadlockTriggered: () {
        _uiLog('[UI_WAITING_STUCK] session=$_kDefaultSessionId runtime=${_runtimeState.status.name}');
        _uiLog('[inference_loop_detected] session=$_kDefaultSessionId waiting=true no_token=true runtime_inferencing=false');
        _uiLog('[UI_SEND_CANCEL] session=$_kDefaultSessionId reason=deadlock_breaker');
        context.read<OrchestratorStateEngine>().add(
              const RecoverFromStuckUiEvent(
                sessionId: _kDefaultSessionId,
                runtimeMessage:
                    'Local runtime stalled before first token. Request cancelled and UI recovered.',
              ),
            );
      },
    );
    _uiLog(
      '[UI_SEND] session=$_kDefaultSessionId page=${hashCode.toRadixString(16)} chars=${text.length} attachments=${attachments.length}',
    );
    _uiLog('[UI_SEND_BEGIN] session=$_kDefaultSessionId chars=${text.length} attachments=${attachments.length}');
    
    context.read<OrchestratorStateEngine>().add(SendMessageEvent(
          sessionId: _kDefaultSessionId,
          userPrompt: text,
          attachments: attachments,
        ));

    _uiLog('[FORENSIC_AFTER_ONSEND]');
  }

  void _handleOrchestratorState(ChatState state) {
    if (state is ChatSending) {
      final hasAssistantToken = state.messages.any(
        (message) => message.role == 'assistant' && message.content.trim().isNotEmpty,
      );
      if (hasAssistantToken && !_deadlockController.isStreamStarted) {
        _deadlockController.handleStreamStarted();
        _uiLog('[UI_STREAM_BEGIN] session=$_kDefaultSessionId');
      }
      return;
    }
    _uiLog('[UI_STREAM_END] session=$_kDefaultSessionId state=${state.runtimeType}');
    _deadlockController.cancelGuard();
  }

  void _appendDebugLabConversation({
    required String prompt,
    required String response,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _debugLabMessages.addAll([
        ChatMessage(
          id: 'debug-lab-user-$now',
          sessionId: 'debug-lab',
          role: 'user',
          content: prompt,
          timestamp: now,
        ),
        ChatMessage(
          id: 'debug-lab-assistant-${now + 1}',
          sessionId: 'debug-lab',
          role: 'assistant',
          content: response,
          timestamp: now + 1,
          provider: 'debug-lab',
        ),
      ]);
    });
    _scrollToBottom();
  }

  void _clearDebugLabMessages() {
    if (!mounted) return;
    setState(() => _debugLabMessages.clear());
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
      builder: (_) => LiveVoiceOverlay(
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
                    voiceEngineActive: _systemIndicatorsSnapshot.voiceEngineActive,
                    gpuAccelerationActive: _hardwareSnapshot.gpuAccelerationActive,
                    gpuBackend: _hardwareSnapshot.gpuBackend,
                    runtimeModeName: _systemIndicatorsSnapshot.runtimeModeName,
                    onStartLiveSession: _openLiveVoiceSession,
                    liveSessionEnabled: !_voiceLoopManager.isSessionActive,
                    debugLabMessages: _debugLabMessages,
                    onAppendDebugLabConversation: _appendDebugLabConversation,
                    onClearDebugLabMessages: _clearDebugLabMessages,
                  )
                : _NarrowLayout(
                    scrollController: _scrollController,
                    onSend: _onSend,
                    onSettings: _openSettings,
                    scrollToBottom: _scrollToBottom,
                    runtimeState: _runtimeState,
                    voiceEngineActive: _systemIndicatorsSnapshot.voiceEngineActive,
                    gpuAccelerationActive: _hardwareSnapshot.gpuAccelerationActive,
                    gpuBackend: _hardwareSnapshot.gpuBackend,
                    runtimeModeName: _systemIndicatorsSnapshot.runtimeModeName,
                    onStartLiveSession: _openLiveVoiceSession,
                    liveSessionEnabled: !_voiceLoopManager.isSessionActive,
                    debugLabMessages: _debugLabMessages,
                    onAppendDebugLabConversation: _appendDebugLabConversation,
                    onClearDebugLabMessages: _clearDebugLabMessages,
                  );
          }),
    );
  }

  static void _uiLog(String message) {
    debugPrint('[CHAT_UI] $message');
  }
}

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
    required this.debugLabMessages,
    required this.onAppendDebugLabConversation,
    required this.onClearDebugLabMessages,
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
  final List<ChatMessage> debugLabMessages;
  final void Function({required String prompt, required String response})
      onAppendDebugLabConversation;
  final VoidCallback onClearDebugLabMessages;

  @override
  Widget build(BuildContext context) {
    return _ChatBody(
      isWide: false,
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
      debugLabMessages: debugLabMessages,
      onAppendDebugLabConversation: onAppendDebugLabConversation,
      onClearDebugLabMessages: onClearDebugLabMessages,
    );
  }
}

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
    required this.debugLabMessages,
    required this.onAppendDebugLabConversation,
    required this.onClearDebugLabMessages,
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
  final List<ChatMessage> debugLabMessages;
  final void Function({required String prompt, required String response})
      onAppendDebugLabConversation;
  final VoidCallback onClearDebugLabMessages;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
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
            isWide: true,
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
             debugLabMessages: debugLabMessages,
             onAppendDebugLabConversation: onAppendDebugLabConversation,
             onClearDebugLabMessages: onClearDebugLabMessages,
           ),
        ),
      ],
    );
  }
}

class _ChatBody extends StatefulWidget {
  const _ChatBody({
    required this.isWide,
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
    required this.debugLabMessages,
    required this.onAppendDebugLabConversation,
    required this.onClearDebugLabMessages,
  });

  final bool isWide;
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
  final List<ChatMessage> debugLabMessages;
  final void Function({required String prompt, required String response})
      onAppendDebugLabConversation;
  final VoidCallback onClearDebugLabMessages;

  @override
  State<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<_ChatBody> {
  final DebugLabController _debugLabController = DebugLabController.instance;
  late final ChatUiPreferencesService _chatUiPreferencesService;
  late final ChatAppearanceViewModel _appearanceViewModel;
  String? _lastSpokenAssistantMessageId;

  @override
  void initState() {
    super.initState();
    _chatUiPreferencesService = di.sl<ChatUiPreferencesService>();
    _appearanceViewModel = ChatAppearanceViewModel();
    _debugLabController.addListener(_handleDebugLabVisibilityChanged);
    _appearanceViewModel.addListener(_handlePresentationStateChanged);
    _loadAssistantTextSize();
  }

  @override
  void dispose() {
    _debugLabController.removeListener(_handleDebugLabVisibilityChanged);
    _appearanceViewModel.removeListener(_handlePresentationStateChanged);
    _appearanceViewModel.dispose();
    super.dispose();
  }

  void _handleDebugLabVisibilityChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _handlePresentationStateChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _loadAssistantTextSize() {
    if (!mounted) return;
    _appearanceViewModel.updateAssistantTextSize(
      _chatUiPreferencesService.assistantMessageTextSize,
    );
  }

  Future<void> _setAssistantTextSize(AssistantMessageTextSize size) async {
    try {
      await _chatUiPreferencesService.setAssistantMessageTextSize(size);
      if (!mounted) return;
      _appearanceViewModel.updateAssistantTextSize(size);
      _uiDebugLog(
        action: 'assistant_text_size_changed',
        sessionId: _kDefaultSessionId,
        details: 'size=${size.name}',
      );
    } catch (error) {
      _uiDebugLog(
        action: 'assistant_text_size_change_failed',
        sessionId: _kDefaultSessionId,
        details: 'error=$error',
      );
    }
  }

  void _clearChatDebug() {
    if (!mounted) return;
    _uiDebugLog(
      action: 'clear_chat_triggered',
      sessionId: _kDefaultSessionId,
    );
    context.read<OrchestratorStateEngine>().add(
          const DebugClearChatEvent(sessionId: _kDefaultSessionId),
        );
    widget.onClearDebugLabMessages();
  }

  void _uiDebugLog({
    required String action,
    required String sessionId,
    String? details,
  }) {
    final timestamp = DateTime.now().toIso8601String();
    final suffix = details == null ? '' : ' $details';
    final message =
        '[UI_DEBUG] action=$action timestamp=$timestamp session_id=$sessionId$suffix';
    debugPrint(message);
    RuntimeEventLog.instance.emit(message);
  }

  Future<void> _speakAssistantResponse(String text) async {
    try {
      await di.sl<VoiceOutputService>().speak(text);
    } catch (error) {
      debugPrint('TTS playback failed: $error');
    }
  }

  AssistantMessageTextSize get _assistantTextSize =>
      _appearanceViewModel.assistantTextSize;

  double get _textScaleFactor => _appearanceViewModel.textScale;

  bool get _localDebugOverlayVisible => _appearanceViewModel.debugLabOpen;

  String? _runtimeMessageForState(ChatState state) {
    if (state is ChatLoaded) return state.runtimeMessage;
    if (state is ChatSending) return state.runtimeMessage;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    const backgroundColor = Color(0xFF131314);
    const surfaceColor = Color(0xFF1E1F20);

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
            unawaited(_speakAssistantResponse(latest.content));
          }
        }
      },
      builder: (context, state) {
        if (state is ChatInitial || state is ChatLoading) {
          return const Scaffold(
            backgroundColor: Color(0xFF131314),
            body: Center(child: CircularProgressIndicator(color: Color(0xFF8AB4F8))),
          );
        }
        if (state is ChatError) {
          return Scaffold(
            backgroundColor: const Color(0xFF131314),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(state.message,
                    style: const TextStyle(color: Colors.redAccent),
                    textAlign: TextAlign.center),
              ),
            ),
          );
        }

        final List<ChatMessage> messages = state is ChatLoaded
            ? state.messages
            : (state is ChatSending ? state.messages : const <ChatMessage>[]);
        final List<ChatMessage> combinedMessages = <ChatMessage>[
          ...messages,
          ...widget.debugLabMessages,
        ];
        final isLoading = state is ChatSending;

        Widget chatMainContent = Column(
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
                    child: combinedMessages.isEmpty
                        ? _buildEmptyState(context)
                        : MediaQuery(
                            data: MediaQuery.of(context).copyWith(
                              textScaler: TextScaler.linear(_textScaleFactor),
                            ),
                            child: HighPerformanceChatList(
                              controller: widget.scrollController,
                              messages: combinedMessages,
                              assistantTextSize: _assistantTextSize,
                            ),
                          ),
                  ),
                  
                  if (_debugLabController.isVisible || _localDebugOverlayVisible)
                    Positioned(
                      top: 10,
                      left: 10,
                      child: DebugOverlay(
                        onSendThroughChatPipeline: widget.onSend,
                        onRenderVoiceInference: ({
                          required String prompt,
                          required String response,
                        }) {
                          widget.onAppendDebugLabConversation(
                            prompt: prompt,
                            response: response,
                          );
                        },
                        onClearChat: _clearChatDebug,
                        assistantTextSize: _assistantTextSize,
                        onAssistantTextSizeChanged: (size) {
                          unawaited(_setAssistantTextSize(size));
                        },
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

        return Scaffold(
          backgroundColor: backgroundColor,
          appBar: AppBar(
            backgroundColor: backgroundColor,
            elevation: 0,
            leading: widget.isWide 
                ? null 
                : Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.menu, color: Color(0xE6FFFFFF)),
                      onPressed: () => Scaffold.of(context).openDrawer(),
                    ),
                  ),
            centerTitle: true,
            title: GestureDetector(
              onTap: _appearanceViewModel.handleSecretPatternClick,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: surfaceColor,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.runtimeModeName.toUpperCase(),
                      style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.arrow_drop_down, color: Colors.white38, size: 16),
                  ],
                ),
              ),
            ),
            actions: [
              PopupMenuButton<int>(
                icon: const Icon(Icons.analytics_outlined, color: Color(0xFF4ADE80)),
                color: surfaceColor,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    enabled: false,
                    child: RuntimeMetricsWidget(
                      runtimeState: widget.runtimeState,
                      voiceEngineActive: widget.voiceEngineActive,
                      gpuAccelerationActive: widget.gpuAccelerationActive,
                      gpuBackend: widget.gpuBackend,
                      runtimeModeName: widget.runtimeModeName,
                    ),
                  )
                ],
              ),
            ],
          ),
          
          drawer: widget.isWide ? null : Drawer(
            backgroundColor: surfaceColor,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Container(
                      width: double.infinity,
                      height: 48,
                      decoration: BoxDecoration(
                        color: const Color(0xFF131314),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: TextButton.icon(
                        onPressed: () {
                          _clearChatDebug();
                          Navigator.of(context).pop();
                        },
                        icon: const Icon(Icons.add, color: Color(0xFF8AB4F8), size: 20),
                        label: const Align(
                          alignment: Alignment.centerLeft,
                          child: Text("Nuova chat", style: TextStyle(color: Color(0xE6FFFFFF), fontWeight: FontWeight.w600, fontSize: 14)),
                        ),
                      ),
                    ),
                  ),
                  
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        ListTile(
                          leading: const Icon(Icons.chat_bubble_outline, color: Color(0xFF8AB4F8), size: 18),
                          title: const Text("Sessione predefinita", style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
                          selected: true,
                          selectedTileColor: Colors.white.withValues(alpha: 0.05),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          onTap: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  
                  const Divider(color: Colors.white12, height: 1),
                  
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text("Scala caratteri chat", style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500)),
                            Text("${(_textScaleFactor * 100).toInt()}%", style: const TextStyle(color: Color(0xFF4ADE80), fontSize: 12, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        Slider(
                          value: _textScaleFactor,
                          min: 0.7,
                          max: 1.7,
                          divisions: 10,
                          activeColor: const Color(0xFF8AB4F8),
                          inactiveColor: Colors.white10,
                          onChanged: (double val) =>
                              _appearanceViewModel.updateTextScale(val),
                        ),
                      ],
                    ),
                  ),
                  
                  const Divider(color: Colors.white12, height: 1),

                  ListTile(
                    leading: const Icon(Icons.account_circle_outlined, color: Colors.white70, size: 22),
                    title: const Text("Dati personali (opzionale)", style: TextStyle(color: Color(0xE6FFFFFF), fontSize: 14)),
                    subtitle: const Text("Profilo utente locale", style: TextStyle(color: Colors.white38, fontSize: 11)),
                    onTap: () {
                      Navigator.of(context).pop();
                      widget.onSettings();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.terminal_outlined, color: Colors.white70, size: 22),
                    title: const Text("Prompt di sistema", style: TextStyle(color: Color(0xE6FFFFFF), fontSize: 14)),
                    subtitle: const Text("Istruzioni di sistema LLM", style: TextStyle(color: Colors.white38, fontSize: 11)),
                    onTap: () {
                      Navigator.of(context).pop();
                      widget.onSettings();
                    },
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
          body: chatMainContent,
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
