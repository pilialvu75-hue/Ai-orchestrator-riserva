import 'package:flutter/material.dart';

class HighPerformanceChatList extends StatelessWidget {
  final List<dynamic> messages;
  final double textSize;
  final ScrollController? controller; // RISOLTO: Ora il parametro nominativo esiste

  const HighPerformanceChatList({
    super.key,
    required this.messages,
    required this.textSize,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const Center(
        child: Text(
          'Nessun messaggio in questa sessione',
          style: TextStyle(color: Color(0xFF8E9194)),
        ),
      );
    }

    return ListView.builder(
      controller: controller, // RISOLTO: Il controller controlla lo scorrimento reale della lista
      cacheExtent: 600.0,
      itemCount: messages.length,
      padding: const EdgeInsets.only(top: 16.0, bottom: 80.0), // Spazio inferiore per non coprire l'input
      itemBuilder: (context, index) {
        final message = messages[index];
        
        // ESTRATTORE DIFENSIVO: Smette di fare il toString() generico del modello
        String text = '';
        bool isUser = false;
        
        try {
          // Tenta l'estrazione dinamica dei campi dal modello dati del BLoC
          text = (message as dynamic).text ?? (message as dynamic).content ?? message.toString();
          final role = (message as dynamic).role?.toString().toLowerCase() ?? '';
          isUser = role == 'user' || ((message as dynamic).isUser == true);
        } catch (_) {
          text = message.toString();
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 16.0),
          child: Align(
            alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              decoration: BoxDecoration(
                color: isUser ? const Color(0xFF2A85FF) : const Color(0xFF2E2F30),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16.0),
                  topRight: const Radius.circular(16.0),
                  bottomLeft: Radius.circular(isUser ? 16.0 : 4.0),
                  bottomRight: Radius.circular(isUser ? 4.0 : 16.0),
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 14.0),
              child: Text(
                text,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: textSize,
                  height: 1.4,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
