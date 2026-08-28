import 'package:flutter/material.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_manifest.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_app_emission_package.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_chat_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_dashboard_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/chat_turn.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';

/// Interfaccia conversazionale principale del Cantiere.
///
/// Il Workshop non viene presentato come una semplice form.
///
/// Flusso:
///
///   Utente
///      ↓
///   Workshop Chat
///      ↓
///   WorkshopChatController
///      ↓
///   WorkshopInferenceGateway
///      ↓
///   RuntimeInferenceProvider
///      ↓
///   risposta del Cantiere
///
/// Quando l'utente conferma una proposta:
///
///   "Sì, procedi"
///        ↓
///   WorkshopDashboardController
///        ↓
///   WorkshopEngine
///        ↓
///   ProjectPlan / Task / Workspace
///
/// La pagina rimane una UI sottile:
///
/// - non esegue shell;
/// - non modifica direttamente il repository;
/// - non bypassa guard;
/// - non decide il provider LLM;
/// - non gestisce la Project Memory persistente.
///
/// La conversazione del Workshop è invece volutamente indipendente
/// dalla Chat Assistente.
class WorkshopDashboardPage extends StatefulWidget {
  const WorkshopDashboardPage({
    super.key,
    WorkshopAppEmissionController? emissionController,
    WorkshopDashboardController? dashboardController,
  })  : _emissionController = emissionController,
        _dashboardController = dashboardController;

  final WorkshopAppEmissionController? _emissionController;
  final WorkshopDashboardController? _dashboardController;

  @override
  State<WorkshopDashboardPage> createState() =>
      _WorkshopDashboardPageState();
}

class _WorkshopDashboardPageState
    extends State<WorkshopDashboardPage> {
  late final WorkshopAppEmissionController
      _emissionController;

  late final WorkshopDashboardController?
      _dashboardController;

  late final WorkshopChatController
      _chatController;

  final TextEditingController
      _messageController =
      TextEditingController();

  final ScrollController
      _scrollController =
      ScrollController();

  bool _pendingConfirmation = false;

  String? _pendingInstruction;
  String? _pendingTitle;

  bool get _ownsDashboardController =>
      widget._dashboardController != null;

  @override
  void initState() {
    super.initState();

    _emissionController =
        widget._emissionController ??
            WorkshopAppEmissionController();

    _dashboardController =
        widget._dashboardController;

    /*
     * Il gateway viene creato attraverso il WorkshopFactory.
     *
     * Questo NON crea un secondo runtime.
     * Riutilizza l'InferenceService già registrato
     * nell'application container.
     *
     * Il Cantiere quindi possiede una propria conversazione
     * ma non dipende dalla Chat Assistente.
     */
    _chatController =
        WorkshopChatController(
      inferenceGateway:
          WorkshopFactory.createInferenceGateway(),
      sessionId:
          'workshop-chat:${DateTime.now().microsecondsSinceEpoch}',
    );

    _chatController.addListener(
      _onChatChanged,
    );

    _dashboardController?.addListener(
      _onDashboardChanged,
    );

    WidgetsBinding.instance.addPostFrameCallback(
      (_) {
        if (mounted) {
          _addWelcomeMessage();
        }
      },
    );
  }

  @override
  void dispose() {
    _chatController.removeListener(
      _onChatChanged,
    );

    _dashboardController?.removeListener(
      _onDashboardChanged,
    );

    _messageController.dispose();
    _scrollController.dispose();

    /*
     * La chat è memoria temporanea.
     *
     * Quando la schermata viene chiusa, la conversazione viene
     * eliminata insieme al controller.
     *
     * La Project Memory persistente verrà gestita separatamente.
     */
    _chatController.clearConversation();
    _chatController.dispose();

    /*
     * Il DashboardController normalmente appartiene all'AppShell.
     * Viene quindi disposto solo quando la pagina ne è realmente
     * proprietaria.
     */
    if (_ownsDashboardController) {
      _dashboardController?.dispose();
    }

    super.dispose();
  }

  void _onChatChanged() {
    if (!mounted) {
      return;
    }

    setState(() {});

    WidgetsBinding.instance.addPostFrameCallback(
      (_) {
        _scrollChatToBottom();
      },
    );
  }

  void _onDashboardChanged() {
    if (!mounted) {
      return;
    }

    setState(() {});
  }

  void _addWelcomeMessage() {
    if (_chatController.hasMessages) {
      return;
    }

    _chatController.addSystemMessage(
      'Ciao. Sono il Cantiere. '
      'Dimmi cosa vuoi costruire e ne discuteremo insieme. '
      'Prima di iniziare la produzione ti mostrerò la proposta '
      'e aspetterò la tua conferma.',
      excludeFromContext: true,
    );
  }

  Future<void> _sendMessage() async {
    final message =
        _messageController.text.trim();

    if (message.isEmpty ||
        _chatController.isBusy) {
      return;
    }

    /*
     * Se l'utente riprende la conversazione dopo una richiesta
     * di conferma, il nuovo messaggio annulla la conferma precedente.
     */
    _pendingConfirmation = false;

    _messageController.clear();

    final result =
        await _chatController.send(
      message,
    );

    if (!mounted) {
      return;
    }

    if (result == null) {
      return;
    }

    /*
     * Manteniamo la prima richiesta utile come istruzione da
     * utilizzare successivamente quando l'utente dirà:
     *
     *   "Sì, procedi."
     */
    if (_pendingInstruction == null) {
      _pendingInstruction =
          _firstUserInstruction();
    }

    _pendingTitle ??=
        _deriveProjectTitle(
      _pendingInstruction,
    );

    /*
     * La prima versione presenta una conferma esplicita dopo
     * una risposta dell'LLM.
     *
     * Il collegamento automatico tra conferma e ProjectPlan
     * avverrà nel passo successivo della pipeline.
     */
    _pendingConfirmation = true;

    setState(() {});
  }

  Future<void> _confirmProposal() async {
    final controller =
        _dashboardController;

    if (controller == null) {
      _showError(
        'Il controller del Cantiere non è collegato.',
      );
      return;
    }

    final instruction =
        _pendingInstruction?.trim();

    if (instruction == null ||
        instruction.isEmpty) {
      _showError(
        'Non è disponibile una richiesta da avviare.',
      );
      return;
    }

    final title =
        (_pendingTitle?.trim().isNotEmpty ?? false)
            ? _pendingTitle!.trim()
            : 'Nuova produzione Cantiere';

    setState(() {
      _pendingConfirmation = false;
    });

    try {
      /*
       * Primo collegamento reale:
       *
       *   conversazione
       *       ↓
       *   conferma utente
       *       ↓
       *   WorkshopRequest
       *       ↓
       *   ProjectPlan
       *
       * Non modifichiamo ancora direttamente il repository.
       */
      controller.startProduction(
        title: title,
        instruction: instruction,
      );

      await _chatController.send(
        'La proposta è approvata. '
        'Procedi con la preparazione della produzione.',
      );

      /*
       * Prepariamo il primo task solo dopo l'approvazione
       * esplicita dell'utente.
       *
       * Il ProjectExecutor continuerà a rispettare
       * WorkspaceSession e i relativi guardrail.
       */
      try {
        await controller.prepareNextTask();
      } catch (error) {
        /*
         * La creazione del piano è già stata completata.
         * Se il workspace/executor non è disponibile, riportiamo
         * il problema nella conversazione senza dichiarare
         * falsamente che la produzione sia iniziata.
         */
        _chatController.addSystemMessage(
          'Il progetto è stato pianificato, ma il primo task '
          'non può ancora essere aperto nello spazio di lavoro: '
          '$error',
          excludeFromContext: true,
        );
      }

      if (!mounted) {
        return;
      }

      setState(() {});

      _showMessage(
        'Produzione approvata e preparazione avviata.',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      _pendingConfirmation = true;

      _showError(
        'Impossibile avviare la produzione: $error',
      );
    }
  }

  void _rejectProposal() {
    if (!mounted) {
      return;
    }

    setState(() {
      _pendingConfirmation = false;
    });

    _messageController.text =
        'No. Voglio modificare la proposta: ';

    WidgetsBinding.instance.addPostFrameCallback(
      (_) {
        if (mounted) {
          FocusScope.of(context)
              .requestFocus(
            _messageFocusNode,
          );
          _messageController.selection =
              TextSelection.fromPosition(
            TextPosition(
              offset:
                  _messageController.text.length,
            ),
          );
        }
      },
    );
  }

  void _startNewConversation() {
    if (!mounted) {
      return;
    }

    setState(() {
      _pendingConfirmation = false;
      _pendingInstruction = null;
      _pendingTitle = null;
    });

    _chatController.clearConversation();
    _addWelcomeMessage();

    _messageController.clear();

    _showMessage(
      'Nuova conversazione del Cantiere.',
    );
  }

  String? _firstUserInstruction() {
    for (final turn
        in _chatController.messages) {
      if (turn.role == ChatRole.user &&
          turn.content.trim().isNotEmpty) {
        return turn.content.trim();
      }
    }

    return null;
  }

  String _deriveProjectTitle(
    String? instruction,
  ) {
    final value =
        instruction?.trim() ?? '';

    if (value.isEmpty) {
      return 'Nuova produzione Cantiere';
    }

    final normalized =
        value.replaceAll(
      RegExp(r'\s+'),
      ' ',
    );

    if (normalized.length <= 48) {
      return normalized;
    }

    return '${normalized.substring(0, 45)}...';
  }

  final FocusNode _messageFocusNode =
      FocusNode();

  void _showMessage(
    String message,
  ) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
        ),
      );
  }

  void _showError(
    String message,
  ) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior:
              SnackBarBehavior.floating,
        ),
      );
  }

  void _scrollChatToBottom() {
    if (!_scrollController.hasClients) {
      return;
    }

    final position =
        _scrollController.position;

    _scrollController.animateTo(
      position.maxScrollExtent,
      duration:
          const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _refresh() {
    if (!mounted) {
      return;
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final emissionState =
        _emissionController.state;

    final packages =
        _emissionController.recent(
      limit: 20,
    );

    final dashboardState =
        _dashboardController?.state;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Cantiere',
        ),
        actions: <Widget>[
          IconButton(
            tooltip:
                'Nuova conversazione',
            onPressed:
                _startNewConversation,
            icon:
                const Icon(Icons.add_comment_outlined),
          ),
          IconButton(
            tooltip:
                'Aggiorna',
            onPressed: _refresh,
            icon:
                const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _WorkshopProjectBar(
            dashboardState:
                dashboardState,
            chatController:
                _chatController,
          ),
          Expanded(
            child:
                _WorkshopConversationView(
              controller:
                  _chatController,
              scrollController:
                  _scrollController,
            ),
          ),
          if (_pendingConfirmation)
            _WorkshopProposalActions(
              busy:
                  _chatController.isBusy ||
                      dashboardState?.isBusy ==
                          true,
              onConfirm:
                  _confirmProposal,
              onReject:
                  _rejectProposal,
            ),
          _WorkshopComposer(
            controller:
                _messageController,
            focusNode:
                _messageFocusNode,
            busy:
                _chatController.isBusy,
            onSend:
                _sendMessage,
          ),
          _WorkshopBottomStatus(
            chatController:
                _chatController,
            dashboardState:
                dashboardState,
          ),
        ],
      ),
      drawer: Drawer(
        child:
            SafeArea(
          child: ListView(
            padding:
                const EdgeInsets.only(
              top: 12,
            ),
            children: <Widget>[
              const DrawerHeader(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  mainAxisAlignment:
                      MainAxisAlignment.end,
                  children: <Widget>[
                    Icon(
                      Icons.construction,
                      size: 42,
                    ),
                    SizedBox(height: 10),
                    Text(
                      'Cantiere',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Factory / Code Studio',
                    ),
                  ],
                ),
              ),
              ListTile(
                leading:
                    const Icon(
                  Icons.chat_outlined,
                ),
                title:
                    const Text(
                  'Conversazione',
                ),
                onTap: () {
                  Navigator.of(
                    context,
                  ).pop();
                },
              ),
              ListTile(
                leading:
                    const Icon(
                  Icons.inventory_2_outlined,
                ),
                title:
                    Text(
                  'App emesse '
                  '(${packages.length})',
                ),
                onTap: () {
                  Navigator.of(
                    context,
                  ).pop();
                  _showMessage(
                    packages.isEmpty
                        ? 'Non ci sono ancora app emesse.'
                        : '${packages.length} app disponibili nell\'output del Cantiere.',
                  );
                },
              ),
              ListTile(
                leading:
                    const Icon(
                  Icons.bug_report_outlined,
                ),
                title:
                    const Text(
                  'Diagnostica',
                ),
                onTap: () {
                  Navigator.of(
                    context,
                  ).pop();
                  _showDiagnostics(
                    emissionState,
                  );
                },
              ),
              const Divider(),
              ListTile(
                leading:
                    const Icon(
                  Icons.refresh,
                ),
                title:
                    const Text(
                  'Nuova conversazione',
                ),
                onTap: () {
                  Navigator.of(
                    context,
                  ).pop();
                  _startNewConversation();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDiagnostics(
    WorkshopAppEmissionState state,
  ) {
    final diagnostics =
        _emissionController
            .diagnostics();

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding:
                const EdgeInsets.fromLTRB(
              16,
              8,
              16,
              24,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Diagnostica Cantiere',
                    style:
                        Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(
                          fontWeight:
                              FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 12),
                  ...diagnostics.entries.map(
                    (entry) =>
                        _WorkshopInfoRow(
                      label: entry.key,
                      value:
                          _formatDiagnosticValue(
                        entry.value,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _formatDiagnosticValue(
    Object? value,
  ) {
    if (value == null) {
      return '—';
    }

    return value.toString();
  }
}

class _WorkshopProjectBar
    extends StatelessWidget {
  const _WorkshopProjectBar({
    required this.dashboardState,
    required this.chatController,
  });

  final WorkshopDashboardControllerState?
      dashboardState;

  final WorkshopChatController
      chatController;

  @override
  Widget build(
    BuildContext context,
  ) {
    final theme =
        Theme.of(context);

    final stage =
        dashboardState?.stage;

    final model =
        chatController.lastModel;

    return Material(
      elevation: 1,
      color:
          theme.colorScheme.surface,
      child: Padding(
        padding:
            const EdgeInsets.fromLTRB(
          16,
          10,
          16,
          10,
        ),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 9,
                  height: 9,
                  decoration:
                      BoxDecoration(
                    color:
                        dashboardState?.isBusy ==
                                true
                            ? theme
                                .colorScheme
                                .tertiary
                            : theme
                                .colorScheme
                                .primary,
                    shape:
                        BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    dashboardState
                            ?.projectTitle ??
                        'Nuova produzione',
                    maxLines: 1,
                    overflow:
                        TextOverflow.ellipsis,
                    style:
                        theme.textTheme.titleSmall
                            ?.copyWith(
                      fontWeight:
                          FontWeight.w700,
                    ),
                  ),
                ),
                if (model != null &&
                    model.trim().isNotEmpty)
                  Flexible(
                    child: Padding(
                      padding:
                          const EdgeInsets.only(
                        left: 8,
                      ),
                      child: Text(
                        model,
                        maxLines: 1,
                        overflow:
                            TextOverflow.ellipsis,
                        style: theme
                            .textTheme
                            .bodySmall,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            _WorkshopStageStrip(
              currentStage: stage,
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkshopStageStrip
    extends StatelessWidget {
  const _WorkshopStageStrip({
    required this.currentStage,
  });

  final WorkshopStage? currentStage;

  @override
  Widget build(
    BuildContext context,
  ) {
    final labels = <String>[
      'Idea',
      'Analisi',
      'Piano',
      'Costruzione',
      'Test',
      'Build',
    ];

    final activeIndex =
        _stageIndex(currentStage);

    return SizedBox(
      height: 6,
      child: Row(
        children: List<Widget>.generate(
          labels.length,
          (index) {
            final active =
                activeIndex >= index;

            return Expanded(
              child: Padding(
                padding:
                    EdgeInsets.only(
                  right:
                      index ==
                              labels.length -
                                  1
                          ? 0
                          : 3,
                ),
                child: DecoratedBox(
                  decoration:
                      BoxDecoration(
                    color: active
                        ? Theme.of(
                            context,
                          )
                            .colorScheme
                            .primary
                        : Theme.of(
                            context,
                          )
                            .colorScheme
                            .surfaceContainerHighest,
                    borderRadius:
                        BorderRadius.circular(
                      20,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  int _stageIndex(
    WorkshopStage? stage,
  ) {
    if (stage == null) {
      return 0;
    }

    switch (stage) {
      case WorkshopStage.requested:
        return 0;
      case WorkshopStage.analysis:
        return 1;
      case WorkshopStage.planning:
        return 2;
      case WorkshopStage.implementation:
        return 3;
      case WorkshopStage.review:
        return 4;
      case WorkshopStage.validation:
        return 4;
      case WorkshopStage.completed:
        return 5;
      case WorkshopStage.blocked:
        return 2;
      case WorkshopStage.cancelled:
        return 0;
    }
  }
}

class _WorkshopConversationView
    extends StatelessWidget {
  const _WorkshopConversationView({
    required this.controller,
    required this.scrollController,
  });

  final WorkshopChatController
      controller;

  final ScrollController
      scrollController;

  @override
  Widget build(
    BuildContext context,
  ) {
    final messages =
        controller.messages;

    if (messages.isEmpty) {
      return const Center(
        child: Text(
          'Scrivi cosa vuoi costruire.',
        ),
      );
    }

    return ListView.builder(
      controller:
          scrollController,
      padding:
          const EdgeInsets.fromLTRB(
        12,
        18,
        12,
        16,
      ),
      physics:
          const AlwaysScrollableScrollPhysics(),
      itemCount:
          messages.length,
      itemBuilder:
          (context, index) {
        final turn =
            messages[index];

        return _WorkshopChatBubble(
          turn: turn,
        );
      },
    );
  }
}

class _WorkshopChatBubble
    extends StatelessWidget {
  const _WorkshopChatBubble({
    required this.turn,
  });

  final ChatTurn turn;

  @override
  Widget build(
    BuildContext context,
  ) {
    final theme =
        Theme.of(context);

    final isUser =
        turn.role ==
            ChatRole.user;

    final isSystem =
        turn.role ==
            ChatRole.system;

    if (isSystem) {
      return Padding(
        padding:
            const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
        child: Container(
          padding:
              const EdgeInsets.all(12),
          decoration:
              BoxDecoration(
            color: theme
                .colorScheme
                .surfaceContainerHighest
                .withValues(
              alpha: 0.6,
            ),
            borderRadius:
                BorderRadius.circular(
              14,
            ),
          ),
          child: Row(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.construction_outlined,
                size: 18,
                color: theme
                    .colorScheme
                    .primary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  turn.content,
                  style: theme
                      .textTheme
                      .bodyMedium,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Align(
      alignment: isUser
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: Container(
        constraints:
            const BoxConstraints(
          maxWidth: 640,
        ),
        margin:
            const EdgeInsets.only(
          bottom: 10,
        ),
        padding:
            const EdgeInsets.fromLTRB(
          15,
          11,
          15,
          11,
        ),
        decoration:
            BoxDecoration(
          color: isUser
              ? theme
                  .colorScheme
                  .primaryContainer
              : theme
                  .colorScheme
                  .surfaceContainerHighest,
          borderRadius:
              BorderRadius.only(
            topLeft:
                const Radius.circular(
              18,
            ),
            topRight:
                const Radius.circular(
              18,
            ),
            bottomLeft:
                Radius.circular(
              isUser ? 18 : 4,
            ),
            bottomRight:
                Radius.circular(
              isUser ? 4 : 18,
            ),
          ),
        ),
        child: Text(
          turn.content,
          style:
              theme.textTheme.bodyLarge,
        ),
      ),
    );
  }
}

class _WorkshopProposalActions
    extends StatelessWidget {
  const _WorkshopProposalActions({
    required this.busy,
    required this.onConfirm,
    required this.onReject,
  });

  final bool busy;
  final VoidCallback onConfirm;
  final VoidCallback onReject;

  @override
  Widget build(
    BuildContext context,
  ) {
    final theme =
        Theme.of(context);

    return Material(
      color:
          theme.colorScheme.surface,
      child: Container(
        padding:
            const EdgeInsets.fromLTRB(
          12,
          8,
          12,
          8,
        ),
        decoration:
            BoxDecoration(
          border:
              Border(
            top:
                BorderSide(
              color: theme
                  .colorScheme
                  .outlineVariant,
            ),
          ),
        ),
        child: Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                'Vuoi che proceda con questa proposta?',
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed:
                  busy ? null : onReject,
              child:
                  const Text('No'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed:
                  busy ? null : onConfirm,
              icon:
                  const Icon(
                Icons.build_outlined,
              ),
              label:
                  const Text(
                'Sì, procedi',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkshopComposer
    extends StatelessWidget {
  const _WorkshopComposer({
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.onSend,
  });

  final TextEditingController
      controller;

  final FocusNode focusNode;

  final bool busy;

  final VoidCallback onSend;

  @override
  Widget build(
    BuildContext context,
  ) {
    final theme =
        Theme.of(context);

    return SafeArea(
      top: false,
      child: Padding(
        padding:
            const EdgeInsets.fromLTRB(
          10,
          6,
          10,
          6,
        ),
        child: Row(
          crossAxisAlignment:
              CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(
              child: TextField(
                controller:
                    controller,
                focusNode:
                    focusNode,
                minLines: 1,
                maxLines: 6,
                textInputAction:
                    TextInputAction.newline,
                enabled:
                    !busy,
                onSubmitted:
                    (_) {
                  if (!busy) {
                    onSend();
                  }
                },
                decoration:
                    InputDecoration(
                  hintText:
                      'Scrivi al Cantiere...',
                  filled:
                      true,
                  fillColor: theme
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(
                    alpha: 0.65,
                  ),
                  contentPadding:
                      const EdgeInsets
                          .symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  border:
                      OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(
                      24,
                    ),
                    borderSide:
                        BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 48,
              height: 48,
              child: FilledButton(
                onPressed:
                    busy
                        ? null
                        : onSend,
                style:
                    FilledButton.styleFrom(
                  shape:
                      const CircleBorder(),
                  padding:
                      EdgeInsets.zero,
                ),
                child: busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child:
                            CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(
                        Icons.send,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkshopBottomStatus
    extends StatelessWidget {
  const _WorkshopBottomStatus({
    required this.chatController,
    required this.dashboardState,
  });

  final WorkshopChatController
      chatController;

  final WorkshopDashboardControllerState?
      dashboardState;

  @override
  Widget build(
    BuildContext context,
  ) {
    final theme =
        Theme.of(context);

    if (chatController.hasError) {
      return Container(
        width: double.infinity,
        padding:
            const EdgeInsets.fromLTRB(
          14,
          7,
          14,
          8,
        ),
        color:
            theme.colorScheme.errorContainer,
        child: Text(
          chatController.lastError!,
          style:
              theme.textTheme.bodySmall
                  ?.copyWith(
            color: theme
                .colorScheme
                .onErrorContainer,
          ),
        ),
      );
    }

    if (dashboardState?.lastError !=
        null) {
      return Container(
        width: double.infinity,
        padding:
            const EdgeInsets.fromLTRB(
          14,
          7,
          14,
          8,
        ),
        color:
            theme.colorScheme.errorContainer,
        child: Text(
          dashboardState!.lastError!,
          style:
              theme.textTheme.bodySmall
                  ?.copyWith(
            color: theme
                .colorScheme
                .onErrorContainer,
          ),
        ),
      );
    }

    if (chatController
            .lastRuntimeNotice !=
        null) {
      return Container(
        width: double.infinity,
        padding:
            const EdgeInsets.fromLTRB(
          14,
          7,
          14,
          8,
        ),
        color:
            theme
                .colorScheme
                .secondaryContainer,
        child: Text(
          chatController
              .lastRuntimeNotice!,
          style:
              theme.textTheme.bodySmall,
        ),
      );
    }

    return const SizedBox.shrink();
  }
}

class _WorkshopInfoRow
    extends StatelessWidget {
  const _WorkshopInfoRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Padding(
      padding:
          const EdgeInsets.only(
        bottom: 8,
      ),
      child: Row(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight:
                    FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty
                  ? '—'
                  : value,
            ),
          ),
        ],
      ),
    );
  }
}
