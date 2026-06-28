import 'package:flutter/material.dart';

class ChatConversation extends StatelessWidget {
  final double textScale;
  final Widget chatList;
  final Widget inputSection;

  const ChatConversation({
    super.key,
    required this.textScale,
    required this.chatList,
    required this.inputSection,
  });

  @override
  Widget build(BuildContext context) {
    // Applica il fattore di scala del testo ereditato dal pannello preferenze/debug
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: Column(
        children: [
          Expanded(
            child: chatList,
          ),
          inputSection,
        ],
      ),
    );
  }
}
