import 'package:flutter/material.dart';

class HighPerformanceChatList extends StatelessWidget {
  final List<dynamic> messages;
  final double textSize;

  const HighPerformanceChatList({
    super.key,
    required this.messages,
    required this.textSize,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: const PageStorageKey('high_perf_chat_list'),
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      itemCount: messages.length,
      // ignore: deprecated_member_use
      cacheExtent: 600.0,
      itemBuilder: (context, index) {
        final message = messages[index];
        
        // Estrazione sicura e dinamica dei dati per evitare crash a runtime
        bool isUser = false;
        String textContent = '';

        try {
          // Rilevamento basato sulle proprietà tipiche dell'entità messaggio (isUser o role)
          isUser = (message as dynamic).isUser == true || 
                   (message as dynamic).role == 'user' || 
                   (message as dynamic).sender == 'user';
          
          textContent = (message as dynamic).content ?? 
                        (message as dynamic).text ?? 
                        message.toString();
        } catch (_) {
          // Fallback robusto in caso di oggetti non standard o stringhe pure
          textContent = message.toString();
          final lowerCaseMsg = textContent.toLowerCase();
          isUser = lowerCaseMsg.startsWith('user:') || lowerCaseMsg.contains('role: user');
        }

        return Padding(
          key: ValueKey(message.hashCode ^ index),
          padding: const EdgeInsets.symmetric(vertical: 6.0),
          child: Align(
            alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.82,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 11.0),
              decoration: BoxDecoration(
                color: isUser ? const Color(0xFF2F80ED) : const Color(0xFF2A2A2C),
                borderRadius: BorderRadius.circular(18.0).copyWith(
                  bottomRight: isUser ? const Radius.circular(2.0) : const Radius.circular(18.0),
                  bottomLeft: isUser ? const Radius.circular(18.0) : const Radius.circular(2.0),
                ),
              ),
              child: SelectionArea(
                child: Text(
                  textContent,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.95),
                    fontSize: textSize,
                    height: 1.45,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
