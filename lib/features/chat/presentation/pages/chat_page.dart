import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/chat_attachment.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_diagnostics_service.dart';
import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_bloc.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_event.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_state.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/settings_page.dart';
import 'package:ai_orchestrator/core/orchestrator/state_engine/orchestrator_state_engine.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_event.dart';
import 'package:ai_orchestrator/features/chat/presentation/bloc/chat_state.dart';
import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_bubble.dart';
import 'package:ai_orchestrator/features/chat/presentation/widgets/chat_input_bar.dart';
import 'package:ai_orchestrator/features/voice/data/services/speech_service.dart';
import 'package:ai_orchestrator/injection_container.dart' as di;

const String _kDefaultSessionId = 'default';

// Width threshold above which a persistent sidebar replaces the Drawer.
const double _kSidebarBreakpoint = 720;

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _scrollController = ScrollController();
  late final LocalRuntimeDiagnosticsService _runtimeDiagnostics;
  LocalRuntimeState _runtimeState = const LocalRuntimeState();

  @override
  void initState() {
    super.initState();
    context
        .read<OrchestratorStateEngine>()
        .add(const LoadMessagesEvent(sessionId: _kDefaultSessionId));
    _runtimeDiagnostics = di.sl<LocalRuntimeDiagnosticsService>();
    _runtimeState = _runtimeDiagnostics.monitor.state;
    _runtimeDiagnostics.monitor.addListener(_handleRuntimeStateChanged);
    final modelBloc = context.read<ModelDownloadBloc>();
    if (modelBloc.state is ModelDownloadInitial) {
      modelBloc.add(const LoadAvailableModels());
    }
  }

  void _handleRuntimeStateChanged(LocalRuntimeState state) {
    if (!mounted) return;
    setState(() => _runtimeState = state);
  }

  @override
  void dispose() {
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
    context.read<OrchestratorStateEngine>().add(SendMessageEvent(
          sessionId: _kDefaultSessionId,
          userPrompt: text,
          attachments: attachments,
        ));
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

  @override
  Widget build(BuildContext context) {
    return BlocListener<ModelDownloadBloc, ModelDownloadState>(
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
                )
              : _NarrowLayout(
                  scrollController: _scrollController,
                  onSend: _onSend,
                  onSettings: _openSettings,
                  scrollToBottom: _scrollToBottom,
                  runtimeState: _runtimeState,
                );
        },
      ),
    );
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
  });

  final ScrollController scrollController;
  final void Function(String text, List<ChatAttachment> attachments) onSend;
  final VoidCallback onSettings;
  final VoidCallback scrollToBottom;
  final LocalRuntimeState runtimeState;

  @override
  Widget build(BuildContext context) {
    return _ChatBody(
      scrollController: scrollController,
      onSend: onSend,
      onSettings: onSettings,
      scrollToBottom: scrollToBottom,
      runtimeState: runtimeState,
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
  });

  final ScrollController scrollController;
  final void Function(String text, List<ChatAttachment> attachments) onSend;
  final VoidCallback onSettings;
  final VoidCallback scrollToBottom;
  final LocalRuntimeState runtimeState;

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
          ),
        ),
      ],
    );
  }
}

class _ChatBody extends StatelessWidget {
  const _ChatBody({
    required this.scrollController,
    required this.onSend,
    required this.onSettings,
    required this.scrollToBottom,
    required this.runtimeState,
  });

  final ScrollController scrollController;
  final void Function(String text, List<ChatAttachment> attachments) onSend;
  final VoidCallback onSettings;
  final VoidCallback scrollToBottom;
  final LocalRuntimeState runtimeState;

  String? _runtimeMessageForState(ChatState state) {
    if (state is ChatLoaded) return state.runtimeMessage;
    if (state is ChatSending) return state.runtimeMessage;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<OrchestratorStateEngine, ChatState>(
      listener: (context, state) {
        if (state is ChatLoaded || state is ChatSending) scrollToBottom();
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
                      onPressed: onSettings,
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
              10;
          if (isRecent &&
              latest.role == 'assistant' &&
              latest.content.trim().isNotEmpty) {
            unawaited(di.sl<SpeechService>().speak(latest.content));
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

        final messages = state is ChatLoaded
            ? state.messages
            : (state is ChatSending ? state.messages : const []);
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
                          const Color(0xFF101526).withOpacity(0.65),
                           const Color(0xFF11192B).withOpacity(0.9),
                           const Color(0xFF0B0F17),
                         ],
                       ),
                     ),
                    child: messages.isEmpty
                        ? _buildEmptyState(context)
                        : ListView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            itemCount: messages.length,
                            itemBuilder: (_, i) => _AnimatedBubble(
                              key: ValueKey(messages[i].id),
                              child: ChatBubble(message: messages[i]),
                            ),
                          ),
                  ),
                  Positioned(
                    top: 10,
                    right: 10,
                    child: IgnorePointer(
                      child: _RuntimeDebugOverlay(runtimeState: runtimeState),
                    ),
                  ),
                ],
              ),
            ),
             ChatInputBar(
               onSend: onSend,
               isLoading: isLoading,
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
                  const Color(0xFF8AB4F8).withOpacity(0.28),
                  Colors.transparent,
                ],
              ),
              border: Border.all(color: const Color(0xFF8AB4F8).withOpacity(0.14)),
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
                  color: Colors.white.withOpacity(0.35), fontSize: 14)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF151A29).withOpacity(0.82),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: Text(
              l10n.t('chat_surface_tagline'),
              style: TextStyle(
                color: Colors.white.withOpacity(0.52),
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

class _RuntimeDebugOverlay extends StatefulWidget {
  const _RuntimeDebugOverlay({required this.runtimeState});

  final LocalRuntimeState runtimeState;

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

  String get _title {
    final message = (widget.runtimeState.message ?? '').toLowerCase();
    switch (widget.runtimeState.status) {
      case LocalRuntimeStatus.loading:
        return 'Loading model';
      case LocalRuntimeStatus.tokenizing:
        return 'Tokenizing';
      case LocalRuntimeStatus.inferring:
        return 'Generating';
      case LocalRuntimeStatus.streaming:
        return 'Streaming';
      case LocalRuntimeStatus.completed:
        return 'Completed';
      case LocalRuntimeStatus.timedOut:
        return 'Timed out';
      case LocalRuntimeStatus.stalled:
        return 'Runtime stalled';
      case LocalRuntimeStatus.ready:
        return 'Runtime ready';
      case LocalRuntimeStatus.missingLibrary:
      case LocalRuntimeStatus.modelMissing:
      case LocalRuntimeStatus.runtimeFailed:
        if (message.startsWith('out of memory') || message.contains('out of memory')) {
          return 'Runtime error';
        }
        return 'Runtime error';
    }
  }

  Color get _color {
    switch (widget.runtimeState.status) {
      case LocalRuntimeStatus.ready:
        return const Color(0xFF8AB4F8);
      case LocalRuntimeStatus.completed:
        return const Color(0xFF4ADE80);
      case LocalRuntimeStatus.streaming:
        return const Color(0xFF7DD3FC);
      case LocalRuntimeStatus.inferring:
      case LocalRuntimeStatus.tokenizing:
      case LocalRuntimeStatus.loading:
        return const Color(0xFFF9A826);
      case LocalRuntimeStatus.timedOut:
        return const Color(0xFFFFB74D);
      case LocalRuntimeStatus.stalled:
      case LocalRuntimeStatus.missingLibrary:
      case LocalRuntimeStatus.modelMissing:
      case LocalRuntimeStatus.runtimeFailed:
        return const Color(0xFFFF8A80);
    }
  }

  Duration get _displayElapsed {
    final state = widget.runtimeState;
    if (state.startedAt != null &&
        (state.status == LocalRuntimeStatus.inferring ||
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
    return Container(
      width: 180,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F131A).withOpacity(0.92),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.35)),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.14),
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
                  _title,
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
            'Tokens ${widget.runtimeState.tokensGenerated}',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            'Time ${elapsed.inSeconds}s',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
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
