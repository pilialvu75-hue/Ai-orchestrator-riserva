import 'package:flutter/material.dart';
import 'chat_app_bar.dart';

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
    return MediaQuery(
      // Applica il fattore di scala del testo proveniente dal Debug Lab
      data: MediaQuery.of(context).copyWith(
        // ignore: deprecated_member_use
        textScaleFactor: textScale,
      ),
      child: Column(
        children: [
          // 1. La vera ed unica ChatAppBar nativa integrata in cima
          const ChatAppBar(),
          
          // 2. Il motore della lista messaggi che occupa tutto lo spazio centrale scaricando la memoria
          Expanded(
            child: chatList,
          ),
          
          // 3. La barra inferiore per tastiera, allegati e microfono
          inputSection,
        ],
      ),
    );
  }
}
