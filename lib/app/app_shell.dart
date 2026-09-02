import 'package:flutter/material.dart';

import '../features/chat/presentation/chat_page.dart';
import '../features/chat/presentation/chat_page_arguments.dart';
import '../features/settings/presentation/settings_page.dart';
import '../app_factory/workshop/workshop_dashboard_controller.dart';
import '../app_factory/workshop/workshop_dashboard_page.dart';
import '../app_factory/workshop/workshop_factory.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key});

  void _openAssistant(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(
          arguments: const ChatPageArguments(),
        ),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const SettingsPage(),
      ),
    );
  }

  Future<void> _openWorkshop(BuildContext context) async {
    final assignments =
        await WorkshopFactory.loadPersistedAssignments();

    if (!context.mounted) {
      return;
    }

    final controller = WorkshopFactory.create(
      workspaceRootPath: null,
      assignments: assignments,
    );

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WorkshopDashboardPage(
          dashboardController: controller,
          modelAssignments: assignments,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Orchestrator'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Assistente',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _openAssistant(context),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Apri Assistente'),
            ),
            const SizedBox(height: 24),
            Text(
              'Cantiere',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _openWorkshop(context),
              icon: const Icon(Icons.construction),
              label: const Text('Apri Cantiere'),
            ),
            const SizedBox(height: 24),
            Text(
              'Impostazioni',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _openSettings(context),
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Apri Impostazioni'),
            ),
          ],
        ),
      ),
    );
  }
}
