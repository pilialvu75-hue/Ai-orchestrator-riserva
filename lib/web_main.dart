import 'package:ai_orchestrator/app_factory/workshop/workshop_chat_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_checkpoint_store.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_checkpoint_storage.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_broker.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_shell.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final cloudBroker = WorkshopWebCloudBrokerClient();
  final chatController = WorkshopChatController(
    inferenceGateway: WorkshopInferenceGateway(
      provider: WorkshopWebCloudRuntimeProvider(
        capability: WorkshopWebCloudCapability.orchestration,
      ),
    ),
    sessionId: 'workshop-web',
  );

  runApp(
    WorkshopWebApp(
      checkpointStore: WorkshopWebCheckpointStorage.open(),
      cloudHealth: cloudBroker.health(),
      chatController: chatController,
    ),
  );
}

class WorkshopWebApp extends StatelessWidget {
  const WorkshopWebApp({
    super.key,
    required this.checkpointStore,
    required this.cloudHealth,
    required this.chatController,
  });

  final Future<WorkshopCheckpointStore> checkpointStore;
  final Future<WorkshopWebCloudBrokerHealth> cloudHealth;
  final WorkshopChatController chatController;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aivexus — Cantiere Web',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF8AB4F8),
          secondary: Color(0xFF6ECBF5),
          surface: Color(0xFF171717),
        ),
        scaffoldBackgroundColor: const Color(0xFF0D0D0D),
      ),
      home: WorkshopWebHome(
        checkpointStore: checkpointStore,
        cloudHealth: cloudHealth,
        chatController: chatController,
      ),
    );
  }
}

class WorkshopWebHome extends StatefulWidget {
  const WorkshopWebHome({
    super.key,
    required this.checkpointStore,
    required this.cloudHealth,
    required this.chatController,
  });

  final Future<WorkshopCheckpointStore> checkpointStore;
  final Future<WorkshopWebCloudBrokerHealth> cloudHealth;
  final WorkshopChatController chatController;

  @override
  State<WorkshopWebHome> createState() => _WorkshopWebHomeState();
}

class _WorkshopWebHomeState extends State<WorkshopWebHome> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: <Widget>[
          WorkshopWebShell(
            checkpointStore: widget.checkpointStore,
            cloudHealth: widget.cloudHealth,
          ),
          WorkshopWebChatPage(controller: widget.chatController),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() => _selectedIndex = index);
        },
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.monitor_heart_outlined),
            selectedIcon: Icon(Icons.monitor_heart),
            label: 'Stato',
          ),
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum),
            label: 'Cantiere',
          ),
        ],
      ),
    );
  }
}

class WorkshopWebChatPage extends StatefulWidget {
  const WorkshopWebChatPage({
    super.key,
    required this.controller,
  });

  final WorkshopChatController controller;

  @override
  State<WorkshopWebChatPage> createState() => _WorkshopWebChatPageState();
}

class _WorkshopWebChatPageState extends State<WorkshopWebChatPage> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant WorkshopWebChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  Future<void> _send() async {
    final message = _inputController.text.trim();
    if (message.isEmpty || widget.controller.isBusy) return;

    _inputController.clear();
    FocusScope.of(context).unfocus();
    await widget.controller.send(message);
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final messages = controller.messages;

    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 24, 24, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Aivexus',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white54,
                          letterSpacing: 1.1,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Cantiere',
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'Conversazione operativa via Cloud / AUTO. '
                        'Le modifiche reali al repository restano dietro i gate di approvazione.',
                        style: TextStyle(
                          color: Colors.white60,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: messages.isEmpty
                    ? const _EmptyConversation()
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          return _MessageBubble(turn: messages[index]);
                        },
                      ),
              ),
              if (controller.hasError)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: _StatusNotice(
                    icon: Icons.error_outline,
                    text: controller.lastError!,
                  ),
                ),
              if (controller.lastRuntimeNotice != null &&
                  controller.lastRuntimeNotice!.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: _StatusNotice(
                    icon: Icons.info_outline,
                    text: controller.lastRuntimeNotice!,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (controller.lastModel != null &&
                        controller.lastModel!.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          'Modello: ${controller.lastModel}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    TextField(
                      controller: _inputController,
                      enabled: !controller.isBusy,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Descrivi cosa vuoi costruire…',
                      ),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: controller.isBusy ? null : _send,
                      icon: controller.isBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send_outlined),
                      label: Text(
                        controller.isBusy ? 'Cantiere al lavoro…' : 'Invia',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'Il broker Cloud / AUTO è pronto.\n'
          'Scrivi una richiesta per iniziare una conversazione con il Cantiere.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white54,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.turn});

  final ChatTurn turn;

  @override
  Widget build(BuildContext context) {
    final isUser = turn.role == ChatRole.user;
    final label = switch (turn.role) {
      ChatRole.user => 'Tu',
      ChatRole.assistant => 'Cantiere',
      ChatRole.system => 'Sistema',
    };

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 620),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isUser
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            SelectableText(
              turn.content,
              style: const TextStyle(height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusNotice extends StatelessWidget {
  const _StatusNotice({
    required this.icon,
    required this.text,
  });

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(height: 1.35),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
