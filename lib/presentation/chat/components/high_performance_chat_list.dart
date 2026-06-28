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
      scrollCacheExtent: 600.0, 
      itemBuilder: (context, index) {
        final message = messages[index];
        
        return Padding(
          key: ValueKey(message.hashCode ^ index),
          padding: const EdgeInsets.symmetric(vertical: 4.0),
          child: Align(
            alignment: Alignment.centerLeft,
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
