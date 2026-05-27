import 'package:flutter/material.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/features/local_ai/domain/entities/ai_model.dart';

/// Card that displays a single AI model with download / select controls.
class ModelDownloadCard extends StatelessWidget {
  const ModelDownloadCard({
    super.key,
    required this.model,
    required this.isSelected,
    this.isRecommended = false,
    this.downloadProgress,
    this.onDownload,
    this.onCancel,
    this.onSelect,
  });

  final AiModel model;
  final bool isSelected;

  /// When `true` a "Recommended" badge is shown alongside the model name.
  final bool isRecommended;

  /// `null` means no active download; 0.0–1.0 means download in progress.
  final double? downloadProgress;

  final VoidCallback? onDownload;
  final VoidCallback? onCancel;
  final VoidCallback? onSelect;

  // ── Role / quantization extraction ─────────────────────────────────────────

  /// Delimiter used to separate metadata segments in model descriptions.
  static const String _descDelimiter = '·';

  /// Extracts a short role label from the description (the first segment before '·').
  String _roleLabel(String description) {
    final parts = description.split(_descDelimiter);
    if (parts.length > 1) return parts[0].trim();
    // Fallback: infer from known IDs
    return '';
  }

  /// Extracts quantization tag from description or file name.
  ///
  /// Matches GGUF quantization suffixes of the form `Q<digit>_K_<LETTERS>`
  /// (e.g. `Q4_K_M`, `Q5_K_S`).  Other quant schemes (e.g. `Q8_0`, `F16`)
  /// are not captured — they would require an extended pattern.
  String? _quantTag(String description, String fileName) {
    final qMatch = RegExp(r'Q\d_K_[A-Z]+').firstMatch(description) ??
        RegExp(r'Q\d_K_[A-Z]+').firstMatch(fileName);
    return qMatch?.group(0);
  }

  /// Maps a platform target to a coloured badge config.
  ({String label, Color color}) _platformBadge(String? platform) {
    return switch (platform) {
      'android' => (label: '🤖 Android', color: const Color(0xFF80CBC4)),
      'windows' => (label: '🪟 Windows', color: const Color(0xFF90CAF9)),
      _ => (label: '🌐 Universal', color: const Color(0xFFA5D6A7)),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final isDownloading = downloadProgress != null;
    final isValidated = model.validationStatus == ModelValidationStatus.validatedOk;
    final sizeLabel = _formatBytes(model.sizeBytes);
    final roleLabel = _roleLabel(model.description);
    final quantTag = _quantTag(model.description, model.fileName);
    final badge = _platformBadge(model.platformTarget);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: isSelected ? const Color(0xFF1A2035) : const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: isSelected
            ? BorderSide(color: theme.colorScheme.primary, width: 2)
            : const BorderSide(color: Color(0xFF2A2A2A), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row ─────────────────────────────────────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Model name + active indicator
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              model.displayName,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: isSelected
                                    ? theme.colorScheme.primary
                                    : Colors.white,
                              ),
                            ),
                          ),
                          if (isSelected) ...[
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.radio_button_checked,
                              size: 14,
                              color: Color(0xFF8AB4F8),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      // Size + version row
                      Text(
                        '${model.version}  •  $sizeLabel',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                // Active badge
                if (isSelected)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      l10n.t('active'),
                      style: TextStyle(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            // ── Badge row ─────────────────────────────────────────────────
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                // Platform badge
                _Badge(label: badge.label, color: badge.color),
                // Role label badge (if extracted)
                if (roleLabel.isNotEmpty)
                  _Badge(
                    label: roleLabel,
                    color: const Color(0xFFCE93D8),
                  ),
                // Quantization badge
                if (quantTag != null)
                  _Badge(
                    label: quantTag,
                    color: const Color(0xFFFFCC80),
                  ),
                // Recommended badge
                if (isRecommended)
                  _Badge(
                    label: '⭐ ${l10n.t('recommended')}',
                    color: const Color(0xFF8AB4F8),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            // ── Description ───────────────────────────────────────────────
            Text(
              // Show clean description (without metadata segments after ·)
              _cleanDescription(model.description),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 14),
            // ── Progress bar (visible only during download) ───────────────
            if (isDownloading) ...[
              Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: downloadProgress,
                      backgroundColor: Colors.white12,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Color(0xFF8AB4F8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${((downloadProgress ?? 0) * 100).toStringAsFixed(0)}%',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF8AB4F8),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            // ── Action buttons ────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (isDownloading)
                  OutlinedButton.icon(
                    onPressed: onCancel,
                    icon: const Icon(Icons.cancel_outlined),
                    label: Text(l10n.t('cancel')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                    ),
                  )
                else if (!model.isDownloaded)
                  FilledButton.icon(
                    onPressed: onDownload,
                    icon: const Icon(Icons.download_rounded),
                    label: Text(l10n.t('download')),
                  )
                else if (!isValidated) ...[
                  FilledButton.icon(
                    onPressed: onDownload,
                    icon: const Icon(Icons.download_rounded),
                    label: Text(l10n.t('download')),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.orangeAccent,
                    ),
                  ),
                ] else ...[
                  if (!isSelected)
                    FilledButton.icon(
                      onPressed: onSelect,
                      icon: const Icon(Icons.check_circle_outline),
                      label: Text(l10n.t('use_this_model')),
                    ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Returns description without the metadata segments (· size · quant · platform).
  String _cleanDescription(String description) {
    final parts = description.split(_descDelimiter);
    // If it's the simple old-style description, return it as-is.
    if (parts.length <= 2) return description;
    // First part is the role label, already shown as badge; show remaining narrative.
    return parts.first.trim();
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1000000000) {
      return '${(bytes / 1000000000).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1000000) {
      return '${(bytes / 1000000).toStringAsFixed(0)} MB';
    }
    return '${(bytes / 1000).toStringAsFixed(0)} KB';
  }
}

// ── Small reusable badge widget ────────────────────────────────────────────────

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
