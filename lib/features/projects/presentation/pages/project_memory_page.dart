import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import 'package:ai_orchestrator/features/projects/presentation/bloc/project_memory_bloc.dart';
import 'package:ai_orchestrator/features/projects/presentation/bloc/project_memory_event.dart';
import 'package:ai_orchestrator/features/projects/presentation/bloc/project_memory_state.dart';
import 'package:ai_orchestrator/features/projects/domain/entities/project_memory.dart';
import 'package:ai_orchestrator/features/projects/presentation/widgets/project_memory_card.dart';

/// Main screen that lists all project-memory snapshots and allows the user to
/// create, view and delete entries.
class ProjectMemoryPage extends StatelessWidget {
  const ProjectMemoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Orchestrator – Memory'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => context
                .read<ProjectMemoryBloc>()
                .add(const LoadProjectMemories()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New Snapshot'),
        onPressed: () => _showCreateDialog(context),
      ),
      body: BlocConsumer<ProjectMemoryBloc, ProjectMemoryState>(
        listener: (context, state) {
          if (state is ProjectMemoryError) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.message),
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
            );
          } else if (state is ProjectMemoryOperationSuccess) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(state.message)),
            );
            context
                .read<ProjectMemoryBloc>()
                .add(const LoadProjectMemories());
          }
        },
        builder: (context, state) {
          if (state is ProjectMemoryLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (state is ProjectMemoriesLoaded) {
            if (state.memories.isEmpty) {
              return const _EmptyState();
            }
            return ListView.builder(
              itemCount: state.memories.length,
              padding: const EdgeInsets.only(bottom: 80),
              itemBuilder: (context, index) {
                final memory = state.memories[index];
                return ProjectMemoryCard(
                  memory: memory,
                  onTap: () => _showDetailDialog(context, memory),
                  onDelete: () => context.read<ProjectMemoryBloc>().add(
                        DeleteProjectMemoryEvent(id: memory.id),
                      ),
                );
              },
            );
          }

          return const _EmptyState();
        },
      ),
    );
  }

  // ── Dialogs ─────────────────────────────────────────────────────────────────

  void _showCreateDialog(BuildContext context) {
    final goalCtrl = TextEditingController();
    final contextCtrl = TextEditingController();
    final snippetCtrl = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('New Project Snapshot'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: goalCtrl,
                decoration:
                    const InputDecoration(labelText: 'Master Goal'),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contextCtrl,
                decoration:
                    const InputDecoration(labelText: 'Current Context'),
                maxLines: 4,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: snippetCtrl,
                decoration: const InputDecoration(
                    labelText: 'Last Code Snippet'),
                maxLines: 6,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final memory = ProjectMemory(
                id: const Uuid().v4(),
                masterGoal: goalCtrl.text.trim(),
                currentContext: contextCtrl.text.trim(),
                lastCodeSnippet: snippetCtrl.text.trim(),
                timestamp: DateTime.now().millisecondsSinceEpoch,
              );
              context
                  .read<ProjectMemoryBloc>()
                  .add(SaveProjectMemoryEvent(projectMemory: memory));
              Navigator.of(dialogCtx).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showDetailDialog(BuildContext context, ProjectMemory memory) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(memory.masterGoal.isEmpty ? 'Memory Detail' : memory.masterGoal),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (memory.currentContext.isNotEmpty) ...[
                const Text('Context:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text(memory.currentContext),
                const SizedBox(height: 12),
              ],
              if (memory.lastCodeSnippet.isNotEmpty) ...[
                const Text('Code Snippet:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    memory.lastCodeSnippet,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ],
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
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.memory,
            size: 80,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'No project memories yet.\nTap + to add your first snapshot.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}
