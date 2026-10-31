import 'package:flutter/material.dart';

/// When a draft gets long on a phone, place the actions below the input
/// so the text uses the full available width. For short drafts and desktop,
/// keep the compact one-row composer. Callbacks and text are unchanged.
class ChatComposerLayout extends StatelessWidget {
  const ChatComposerLayout({
    super.key,
    required this.wideDraft,
    required this.menuButton,
    required this.messageField,
    required this.voiceButton,
    required this.sendButton,
  });

  final bool wideDraft;
  final Widget menuButton;
  final Widget messageField;
  final Widget voiceButton;
  final Widget sendButton;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (wideDraft && constraints.maxWidth < 520) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              messageField,
              const SizedBox(height: 4),
              Row(
                children: [
                  menuButton,
                  const Spacer(),
                  voiceButton,
                  const SizedBox(width: 6),
                  sendButton,
                ],
              ),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            menuButton,
            const SizedBox(width: 8),
            Expanded(child: messageField),
            const SizedBox(width: 6),
            voiceButton,
            const SizedBox(width: 6),
            sendButton,
          ],
        );
      },
    );
  }
}
