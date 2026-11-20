import 'package:flutter/material.dart';

/// Display-only target for the Web Studio preview. This is deliberately not a
/// build target or a generator request parameter: the current preview is Web.
enum WorkshopWebTarget {
  android,
  ios,
  macos,
  windows,
  linux,
  web;

  String get label => switch (this) {
        WorkshopWebTarget.android => 'Android',
        WorkshopWebTarget.ios => 'iOS',
        WorkshopWebTarget.macos => 'macOS',
        WorkshopWebTarget.windows => 'Windows',
        WorkshopWebTarget.linux => 'Linux',
        WorkshopWebTarget.web => 'Web',
      };

  IconData get icon => switch (this) {
        WorkshopWebTarget.android => Icons.android,
        WorkshopWebTarget.ios => Icons.phone_iphone,
        WorkshopWebTarget.macos => Icons.laptop_mac,
        WorkshopWebTarget.windows => Icons.window_outlined,
        WorkshopWebTarget.linux => Icons.computer,
        WorkshopWebTarget.web => Icons.language,
      };

  bool get isPhone =>
      this == WorkshopWebTarget.android || this == WorkshopWebTarget.ios;

  static WorkshopWebTarget fromCode(String? code) {
    for (final target in WorkshopWebTarget.values) {
      if (target.name == code) return target;
    }
    return WorkshopWebTarget.web;
  }
}

/// Compact shared selector for the first prompt and the preview toolbar.
class WorkshopWebPlatformPicker extends StatelessWidget {
  const WorkshopWebPlatformPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final WorkshopWebTarget selected;
  final ValueChanged<WorkshopWebTarget> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<WorkshopWebTarget>(
      key: const Key('web_platform_picker'),
      tooltip: 'Seleziona piattaforma',
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final target in WorkshopWebTarget.values)
          CheckedPopupMenuItem<WorkshopWebTarget>(
            key: Key('web_platform_option_' + target.name),
            value: target,
            checked: target == selected,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(target.icon, size: 19),
                const SizedBox(width: 10),
                Text(target.label),
              ],
            ),
          ),
      ],
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1B2533),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF46566A)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(selected.icon, size: 19),
            const SizedBox(width: 8),
            Text(selected.label, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            const Icon(Icons.expand_more, size: 19),
          ],
        ),
      ),
    );
  }
}
