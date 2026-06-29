import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

// Importazione dei componenti satelliti
import 'package:ai_orchestrator/presentation/chat/components/chat_conversation.dart';
import 'package:ai_orchestrator/presentation/chat/components/high_performance_chat_list.dart';
import 'package:ai_orchestrator/presentation/chat/components/runtime_metrics_widget.dart';
import 'package:ai_orchestrator/presentation/chat/components/chat_input_section.dart';
import 'package:ai_orchestrator/presentation/chat/components/debug_lab_overlay.dart';

// Importazione dei controllori e dei view model di Fase 2
import 'package:ai_orchestrator/presentation/chat/controllers/runtime_state_controller.dart';
import 'package:ai_orchestrator/presentation/chat/controllers/execution_hardware_controller.dart';
import 'package:ai_orchestrator/presentation/chat/controllers/system_indicators_controller.dart';
import 'package:ai_orchestrator/presentation/chat/controllers/chat_deadlock_controller.dart';
import 'package:ai_orchestrator/presentation/chat/view_models/chat_appearance_view_model.dart';

// Servizi infrastrutturali core
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_diagnostics_service.dart';
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
  final _scrollController = ScrollController();
  
  late final LocalRuntimeDiagnosticsService _runtimeDiagnostics;
  late final AiRuntimeSettingsService _runtimeSettings;
  late final VoiceEngine _voiceEngine;
  
  // Architettura di controllo di Fase 2 completata
  late final RuntimeStateController _runtimeStateController;
  late final ExecutionHardwareController _hardwareController;
  late final SystemIndicatorsController _indicatorsController;
  late final ChatDeadlockController _deadlockController;
  late final ChatAppearanceViewModel _appearanceViewModel;

  List<dynamic> _cachedMessages = const [];

  @override
  void initState() {
    super.initState();
    context.read<OrchestratorStateEngine>().add(const LoadMessagesEvent(sessionId: _kDefaultSessionId));
    
    _runtimeDiagnostics = di.sl<LocalRuntimeDiagnosticsService>();
    _runtimeSettings = di.sl<AiRuntimeSettingsService>();
    _voiceEngine = di.sl<VoiceEngine>();
    
    _runtimeStateController = RuntimeStateController(diagnostics: _runtimeDiagnostics);
    _hardwareController = ExecutionHardwareController();
    _indicatorsController = SystemIndicatorsController(
      runtimeSettings: _runtimeSettings,
      voiceEngine: _voiceEngine,
    );
    _deadlockController = ChatDeadlockController();
    _appearanceViewModel = ChatAppearanceViewModel();
    
    WidgetsBinding.instance.addObserver(this);
    _runtimeStateController.startMonitoring(_kRuntimeStatePollInterval);
    unawaited(_refreshRuntimeIndicators());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _runtimeStateController.startMonitoring(_kRuntimeStatePollInterval);
    } else {
      _runtimeStateController.stopMonitoring();
    }
  }

  Future<void> _refreshRuntimeIndicators() async {
    await _hardwareController.updateHardwareStatus();
    await _indicatorsController.refreshIndicators();
  }

  void _onSend(String text) {
    debugPrint('[CHAT_UI] [FORENSIC_BEFORE_ONSEND] chars=${text.length}');
    _deadlockController.handleSendBegan();
    
    _deadlockController.startGuard(
      isSending: true,
      isInferencing: _runtimeStateController.isInferencing(),
      onDeadlockTriggered: () {
        context.read<OrchestratorStateEngine>().add(
              const RecoverFromStuckUiEvent(
                sessionId: _kDefaultSessionId,
                runtimeMessage: 'Local runtime stalled before first token. Request cancelled and UI recovered.',
              ),
            );
      },
    );
    
    context.read<OrchestratorStateEngine>().add(SendMessageEvent(
          sessionId: _kDefaultSessionId,
          userPrompt: text,
          attachments: const [],
        ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF131314),
      body: ListenableBuilder(
        listenable: _appearanceViewModel,
        builder: (context, _) {
          return Stack(
            children: [
              BlocBuilder<OrchestratorStateEngine, ChatState>(
                builder: (context, chatState) {
                  List<dynamic> currentMessages = _cachedMessages;
                  try {
                    final stateMessages = (chatState as dynamic).messages;
                    if (stateMessages != null) {
                      currentMessages = stateMessages;
                      _cachedMessages = stateMessages;
                    }
                  } catch (_) {}
                  
                  // Se lo streaming è iniziato, aggiorna il controllore di deadlock
                  if (chatState is! ChatSending && chatState is! ChatInitial) {
                    _deadlockController.cancelGuard();
                  }
                  
                  return ChatConversation(
                    textScale: _appearanceViewModel.textScale,
                    title: 'Phi-3.5-mini',
                    onTitlePressed: _appearanceViewModel.handleSecretPatternClick,
                    onSettingsPressed: _appearanceViewModel.toggleMetrics,
                    chatList: HighPerformanceChatList(
                      messages: currentMessages,
                      textSize: _appearanceViewModel.assistantTextSize,
                      controller: _scrollController, // CONNESSO: Ora la lista segue lo scorrimento
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
              if (_appearanceViewModel.showMetrics)
                ValueListenableBuilder<ChatRuntimeSnapshot>(
                  valueListenable: _runtimeStateController,
                  builder: (context, runtimeSnapshot, _) {
                    return ValueListenableBuilder<HardwareSnapshot>(
                      valueListenable: _hardwareController,
                      builder: (context, hardwareSnapshot, _) {
                        return ValueListenableBuilder<SystemIndicatorsSnapshot>(
                          valueListenable: _indicatorsController,
                          builder: (context, indicatorsSnapshot, _) {
                            return RuntimeMetricsWidget(
                              monitorState: runtimeSnapshot.state,
                              voiceEngineActive: indicatorsSnapshot.voiceEngineActive,
                              gpuAccelerationActive: hardwareSnapshot.gpuAccelerationActive,
                              gpuBackend: hardwareSnapshot.gpuBackend,
                              runtimeModeName: indicatorsSnapshot.runtimeModeName,
                              onClose: () => _appearanceViewModel.setMetricsVisibility(false),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              if (_appearanceViewModel.debugLabOpen)
                DebugLabOverlay(
                  onToggleMetrics: _appearanceViewModel.toggleMetricsFromLab,
                  onTextScaleChanged: _appearanceViewModel.updateTextScale,
                  onFontSizeChanged: _appearanceViewModel.updateFontSize,
                  currentTextScale: _appearanceViewModel.textScale,
                  currentFontSize: _appearanceViewModel.assistantTextSize,
                  onClose: _appearanceViewModel.closeDebugLab,
                ),
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _runtimeStateController.dispose();
    _hardwareController.dispose();
    _indicatorsController.dispose();
    _deadlockController.dispose();
    _appearanceViewModel.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}
