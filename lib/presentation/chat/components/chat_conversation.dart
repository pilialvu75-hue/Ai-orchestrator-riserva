import 'package:flutter/material.dart';
import 'package:ai_orchestrator/presentation/chat/components/chat_app_bar.dart';

class ChatConversation extends StatelessWidget {
  final double textScale;
  final Widget chatList;
  final Widget inputSection;
  final String title;
  final VoidCallback onTitlePressed;
  final VoidCallback onSettingsPressed;

  const ChatConversation({
    super.key,
    required this.textScale,
    required this.chatList,
    required this.inputSection,
    required this.title,
    required this.onTitlePressed,
    required this.onSettingsPressed,
  });

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: Column(
        children: [
          ChatAppBar(
            title: title,
            onTitlePressed: onTitlePressed,
            onSettingsPressed: onSettingsPressed,
          ),
          
          Expanded(
            child: chatList,
          ),
          
          inputSection,
        ],
      ),
    );
  }
}
