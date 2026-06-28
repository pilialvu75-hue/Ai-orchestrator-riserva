import 'package:flutter/material.dart';

class HighPerformanceChatList extends StatelessWidget {
  final List<dynamic> messages; // Mantenuto dynamic per non forzare il tipo del modello dati in Fase 1
  final double textSize;

  const HighPerformanceChatList({
    super.key,
    required this.messages,
    required this.textSize,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      // Mantiene la posizione dello scroll durante il rebuild della pagina
      key: const PageStorageKey('high_perf_chat_list'),
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      itemCount: messages.length,
      // Ottimizzazione della viewport per ridurre i cicli di pittura su Mobile/Embedded
      cacheExtent: 600.0, 
      itemBuilder: (context, index) {
        final message = messages[index];
        
        // Struttura pura della bolla ereditata dal file monolitico.
        // In questa fase, consuma semplicemente la proprietà 'textSize' per l'assistente.
        return Padding(
          key: ValueKey(message.hashCode ^ index),
          padding: const EdgeInsets.symmetric(vertical: 4.0),
          child: Align(
            alignment: Alignment.centerLeft, // Orientamento derivato dal rendering legacy
            child: Text(
              message.toString(),
              style: TextStyle(
                fontSize: textSize,
              ),
            ),
          ),
        );
      },
    );
  }
}
