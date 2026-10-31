import 'package:flutter/material.dart';

/// Shows the *configured* AI routing mode, not a verified provider receipt.
///
/// The label keeps the existing seven-tap developer gesture. The explicit
/// settings icon is the user-facing way to choose a mode; opening it cannot
/// change a runtime preference without the settings page's Save action.
class ChatRuntimeModeShortcut extends StatelessWidget {
  const ChatRuntimeModeShortcut({
    super.key,
    required this.modeName,
    required this.settingsTooltip,
    required this.onOpenSettings,
    required this.onDeveloperTap,
  });

  final String modeName;
  final String settingsTooltip;
  final VoidCallback onOpenSettings;
  final VoidCallback onDeveloperTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          key: const Key('chat-runtime-mode-label'),
          behavior: HitTestBehavior.opaque,
          onTap: onDeveloperTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              modeName.toUpperCase(),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(width: 3),
        IconButton(
          key: const Key('chat-runtime-mode-settings'),
          tooltip: settingsTooltip,
          onPressed: onOpenSettings,
          icon: const Icon(
            Icons.settings_outlined,
            color: Colors.white54,
            size: 16,
          ),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(
            minWidth: 28,
            minHeight: 28,
          ),
          splashRadius: 16,
        ),
      ],
    );
  }
}
