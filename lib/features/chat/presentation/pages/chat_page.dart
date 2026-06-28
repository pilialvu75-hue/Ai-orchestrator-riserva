// =========================================================================
// AI-Orchestrator - Presentation Layer
// file: lib/presentation/chat/chat_page.dart
//
// 🗺️ MAPPA DEI COMPONENTI ESTRATTI (FASE 1: SOLO ESTRAZIONE GRAFICA)
// -------------------------------------------------------------------------
// 📍 AppBar e Status Indicatori   -> presentation/chat/components/chat_app_bar.dart
// 📍 Contenitore Area Conversazione -> presentation/chat/components/chat_conversation.dart
// 📍 Lista Messaggi Virtualizzata -> presentation/chat/components/high_performance_chat_list.dart
// 📍 Pannello Overlay Metriche     -> presentation/chat/components/runtime_metrics_widget.dart
// 📍 Barra Input e Pannello Vocale -> presentation/chat/components/chat_input_section.dart
// 📍 Pannello Lab Segreto (Debug)  -> presentation/chat/components/debug_lab_overlay.dart
// =========================================================================

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

// Importazioni temporanee dei componenti estratti in Fase 1
import 'components/chat_app_bar.dart';
import 'components/chat_conversation.dart';
import 'components/high_performance_chat_list.dart';
import 'components/runtime_metrics_widget.dart';
import 'components/chat_input_section.dart';
import 'components/debug_lab_overlay.dart';

// Importazioni dei servizi e dello stato legacy (immutati in Fase 1)
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_diagnostics_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/voice/voice_engine.dart';
import 'package:ai_orchestrator/application/chat/orchestrator_state_engine.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  // 💡 LOGICA LEGACY: Invariata in Fase 1 per azzerare i rischi di regressione.
  // Sarà migrata nei rispettivi ViewModel (Runtime, Appearance, Debug) solo in Fase 2.
  late final LocalRuntimeDiagnosticsService _diagnostics;
  late final AiRuntimeSettingsService _settings;
  late final VoiceEngine _voiceEngine;
  
  // Parametri di stato temporanei per polling, debug e preferenze visive grafiche
  bool _showMetrics = false;
  bool _debugLabOpen = false;
  double _textScale = 1.0;
  double _assistantTextSize = 14.0;
  int _secretClickCount = 0;

  @override
  void initState() {
    super.initState();
    _diagnostics = RepositoryProvider.of<LocalRuntimeDiagnosticsService>(context);
    _settings = RepositoryProvider.of<AiRuntimeSettingsService>(context);
    _voiceEngine = RepositoryProvider.of<VoiceEngine>(context);
    
    // Il vecchio ciclo di sincronizzazione/polling rimane intatto qui per la Fase 1
    _startLegacyPolling();
  }

  void _startLegacyPolling() {
    // Logica originale di polling temporizzato...
  }

  // 💡 FUNZIONI DI NAVIGAZIONE E AZIONE INTERNE
  // Rimangono temporaneamente nello State della pagina per non toccare la logica.
  void _handleSettingsNavigation() {
    Navigator.of(context).pushNamed('/settings');
  }

  void _handleVoiceOverlayOpen() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => const SizedBox(height: 350, child: Center(child: Text('Voice Session'))),
    );
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
    return BlocBuilder<OrchestratorStateEngine, ChatState>(
      builder: (context, chatState) {
        return Scaffold(
          // 📍 ESTRATTO -> presentation/chat/components/chat_app_bar.dart
          appBar: ChatAppBar(
            title: 'AI-Orchestrator',
            onSettingsPressed: _handleSettingsNavigation,
            onTitlePressed: _handleSecretPatternClick,
          ),
          body: Stack(
            children: [
              // 📍 ESTRATTO -> presentation/chat/components/chat_conversation.dart
              ChatConversation(
                textScale: _textScale,
                // 📍 ESTRATTO -> presentation/chat/components/high_performance_chat_list.dart
                chatList: HighPerformanceChatList(
                  messages: chatState.messages,
                  textSize: _assistantTextSize,
                ),
                // 📍 ESTRATTO -> presentation/chat/components/chat_input_section.dart
                inputSection: ChatInputSection(
                  onSend: (text) => context.read<OrchestratorStateEngine>().add(SendMessageEvent(text)),
                  onVoicePressed: _handleVoiceOverlayOpen,
                  isSending: chatState is ChatSendingState,
                ),
              ),

              // 📍 ESTRATTO -> presentation/chat/components/runtime_metrics_widget.dart
              if (_showMetrics)
                RuntimeMetricsWidget(
                  monitorState: _diagnostics.monitor.state,
                  onClose: () => setState(() => _showMetrics = false),
                ),

              // 📍 ESTRATTO -> presentation/chat/components/debug_lab_overlay.dart
              if (_debugLabOpen)
                DebugLabOverlay(
                  onToggleMetrics: () => setState(() => _showMetrics = !_showMetrics),
                  onTextScaleChanged: (scale) => setState(() => _textScale = scale),
                  onFontSizeChanged: (size) => setState(() => _assistantTextSize = size),
                  currentTextScale: _textScale,
                  currentFontSize: _assistantTextSize,
                  onClose: () => setState(() => _debugLabOpen = false),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    // Pulizia risorse legacy
    super.dispose();
  }
}
