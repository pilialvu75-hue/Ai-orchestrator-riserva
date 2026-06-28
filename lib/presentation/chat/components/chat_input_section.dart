import 'package:flutter/material.dart';

class ChatInputSection extends StatefulWidget {
  final ValueChanged<String> onSend;
  final VoidCallback onVoicePressed;
  final bool isSending;

  const ChatInputSection({
    super.key,
    required this.onSend,
    required this.onVoicePressed,
    required this.isSending,
  });

  @override
  State<ChatInputSection> createState() => _ChatInputSectionState();
}

class _ChatInputSectionState extends State<ChatInputSection> {
  final TextEditingController _controller = TextEditingController();

  void _handleSubmit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty && !widget.isSending) {
      widget.onSend(text);
      _controller.clear();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        boxShadow: [
          BoxShadow(
            offset: const Offset(0, -1),
            blurRadius: 4.0,
            color: Colors.black.withValues(alpha: 0.05),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.mic_none_outlined),
              onPressed: widget.isSending ? null : widget.onVoicePressed,
              tooltip: 'Attiva Input Vocale',
            ),
            Expanded(
              child: TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  hintText: 'Invia un messaggio...',
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8.0),
                ),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _handleSubmit(),
                enabled: !widget.isSending,
              ),
            ),
            IconButton(
              icon: widget.isSending
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded),
              onPressed: widget.isSending ? null : _handleSubmit,
              tooltip: 'Invia Messaggio',
            ),
          ],
        ),
      ),
    );
  }
}
