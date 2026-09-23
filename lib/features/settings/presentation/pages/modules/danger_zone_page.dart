import 'package:ai_orchestrator/features/settings/data/services/assistant_data_reset_service.dart';
import 'package:flutter/material.dart';

class DangerZonePage extends StatefulWidget {
  const DangerZonePage({
    super.key,
    required this.resetService,
  });

  final AssistantDataResetService resetService;

  @override
  State<DangerZonePage> createState() => _DangerZonePageState();
}

class _DangerZonePageState extends State<DangerZonePage> {
  bool _recentContext = false;
  bool _chatHistory = false;
  bool _semanticChatIndex = false;
  bool _durableMemory = false;
  bool _projectMemory = false;
  bool _running = false;

  AssistantDataResetSelection get _selection => AssistantDataResetSelection(
        recentContext: _recentContext,
        chatHistory: _chatHistory,
        semanticChatIndex: _semanticChatIndex,
        durableMemory: _durableMemory,
        projectMemory: _projectMemory,
      );

  @override
  Widget build(BuildContext context) {
    const danger = Color(0xFFFF6B6B);
    final selection = _selection;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF151515),
        foregroundColor: Colors.white,
        title: const Text('Danger Zone'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: danger.withValues(alpha: 0.28),
                ),
              ),
              child: const Text(
                'These actions permanently erase local Assistant memory. '
                'They do not delete models, downloaded assets, credentials, '
                'provider/runtime settings or project source files.',
                style: TextStyle(
                  color: Colors.white70,
                  height: 1.45,
                ),
              ),
            ),
            const SizedBox(height: 18),
            _ResetOption(
              title: 'Recent conversation context',
              subtitle:
                  'Clears the in-memory rolling context and starts a fresh session.',
              value: _recentContext,
              enabled: !_running,
              onChanged: (value) => setState(() => _recentContext = value),
            ),
            _ResetOption(
              title: 'Chat history',
              subtitle: 'Deletes persisted Assistant messages from all sessions.',
              value: _chatHistory,
              enabled: !_running,
              onChanged: (value) => setState(() => _chatHistory = value),
            ),
            _ResetOption(
              title: 'Semantic chat index',
              subtitle:
                  'Deletes embeddings derived from conversations, without touching document/project indexes.',
              value: _semanticChatIndex,
              enabled: !_running,
              onChanged: (value) => setState(() => _semanticChatIndex = value),
            ),
            _ResetOption(
              title: 'Durable Assistant memory',
              subtitle:
                  'Deletes confirmed/candidate durable memory across user, conversation and project scopes.',
              value: _durableMemory,
              enabled: !_running,
              onChanged: (value) => setState(() => _durableMemory = value),
            ),
            _ResetOption(
              title: 'Project memory',
              subtitle:
                  'Deletes retained Assistant project-memory records, not project files or Cantiere workspaces.',
              value: _projectMemory,
              enabled: !_running,
              onChanged: (value) => setState(() => _projectMemory = value),
            ),
            const SizedBox(height: 18),
            FilledButton.tonalIcon(
              onPressed: !_running && !selection.isEmpty
                  ? () => _confirmAndReset(selection, global: false)
                  : null,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Erase selected data'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: danger,
                foregroundColor: Colors.black,
              ),
              onPressed: _running
                  ? null
                  : () => _confirmAndReset(
                        const AssistantDataResetSelection.all(),
                        global: true,
                      ),
              icon: _running
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.warning_amber_rounded),
              label: const Text('Erase ALL Assistant memory'),
            ),
            const SizedBox(height: 16),
            Text(
              'Global erase requires typing ELIMINA before the action can run. '
              'A partial failure is reported category by category; nothing is '
              'silently treated as erased.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmAndReset(
    AssistantDataResetSelection selection, {
    required bool global,
  }) async {
    if (_running || selection.isEmpty) return;

    final confirmed = global
        ? await _confirmGlobalReset()
        : await _confirmSelectedReset(selection);
    if (confirmed != true || !mounted) return;

    setState(() => _running = true);
    try {
      final report = await widget.resetService.reset(selection);
      if (!mounted) return;
      await _showReport(report);
      if (report.complete) {
        setState(() {
          _recentContext = false;
          _chatHistory = false;
          _semanticChatIndex = false;
          _durableMemory = false;
          _projectMemory = false;
        });
      }
    } on Object catch (error) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF171717),
          title: const Text(
            'Reset not started',
            style: TextStyle(color: Colors.white),
          ),
          content: Text(
            error.toString(),
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<bool?> _confirmSelectedReset(
    AssistantDataResetSelection selection,
  ) {
    final labels = _selectedLabels(selection);
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF171717),
        title: const Text(
          'Erase selected Assistant data?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          labels.map((item) => '• $item').join('\n'),
          style: const TextStyle(
            color: Colors.white70,
            height: 1.55,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Erase'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmGlobalReset() {
    final controller = TextEditingController();
    return showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final confirmed =
              controller.text.trim().toUpperCase() == 'ELIMINA';
          return AlertDialog(
            backgroundColor: const Color(0xFF171717),
            title: const Text(
              'Erase ALL Assistant memory?',
              style: TextStyle(color: Colors.white),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This erases recent context, all chat history, semantic chat '
                  'embeddings, durable Assistant memory and retained project memory.',
                  style: TextStyle(
                    color: Colors.white70,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Type ELIMINA to confirm:',
                  style: TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'ELIMINA',
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed:
                    confirmed ? () => Navigator.of(context).pop(true) : null,
                child: const Text('Erase everything'),
              ),
            ],
          );
        },
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _showReport(AssistantDataResetReport report) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF171717),
        title: Text(
          report.complete
              ? 'Assistant memory erased'
              : report.partial
                  ? 'Reset partially completed'
                  : 'Reset failed',
          style: const TextStyle(color: Colors.white),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final outcome in report.outcomes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    outcome.success
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    color: outcome.success
                        ? const Color(0xFF34D399)
                        : const Color(0xFFFF6B6B),
                  ),
                  title: Text(
                    _labelFor(outcome.category),
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    outcome.success
                        ? outcome.removedItems == null
                            ? 'Cleared'
                            : '${outcome.removedItems} records erased'
                        : outcome.error ?? 'Unknown error',
                    style: const TextStyle(color: Colors.white60),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  List<String> _selectedLabels(AssistantDataResetSelection selection) {
    return <AssistantDataResetCategory>[
      for (final category in AssistantDataResetCategory.values)
        if (selection.includes(category)) category,
    ].map(_labelFor).toList(growable: false);
  }

  String _labelFor(AssistantDataResetCategory category) => switch (category) {
        AssistantDataResetCategory.recentContext =>
          'Recent conversation context',
        AssistantDataResetCategory.chatHistory => 'Chat history',
        AssistantDataResetCategory.semanticChatIndex => 'Semantic chat index',
        AssistantDataResetCategory.durableMemory =>
          'Durable Assistant memory',
        AssistantDataResetCategory.projectMemory => 'Project memory',
      };
}

class _ResetOption extends StatelessWidget {
  const _ResetOption({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: enabled ? (value) => onChanged(value ?? false) : null,
      activeColor: const Color(0xFFFF6B6B),
      checkColor: Colors.black,
      title: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          color: Colors.white60,
          height: 1.35,
        ),
      ),
      controlAffinity: ListTileControlAffinity.leading,
    );
  }
}
