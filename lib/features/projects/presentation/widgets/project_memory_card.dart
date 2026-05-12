import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:ai_orchestrator/features/projects/domain/entities/project_memory.dart';

/// A card widget that displays a summary of a [ProjectMemory] entry.
class ProjectMemoryCard extends StatelessWidget {
  const ProjectMemoryCard({
    super.key,
    required this.memory,
    this.onTap,
    this.onDelete,
  });

  final ProjectMemory memory;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formattedDate = DateFormat('dd MMM yyyy – HH:mm').format(
      DateTime.fromMillisecondsSinceEpoch(memory.timestamp),
    );

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header row ────────────────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: Text(
                      memory.masterGoal.isEmpty
                          ? 'No goal set'
                          : memory.masterGoal,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (onDelete != null)
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      color: theme.colorScheme.error,
                      onPressed: onDelete,
                      tooltip: 'Delete',
                    ),
                ],
              ),

              const SizedBox(height: 8),

              // ── Context ───────────────────────────────────────────────────
              if (memory.currentContext.isNotEmpty) ...[
                Text(
                  memory.currentContext,
                  style: theme.textTheme.bodyMedium,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
              ],

              // ── Code snippet preview ──────────────────────────────────────
              if (memory.lastCodeSnippet.isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    memory.lastCodeSnippet,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 8),
              ],

              // ── Footer ────────────────────────────────────────────────────
              Text(
                formattedDate,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
