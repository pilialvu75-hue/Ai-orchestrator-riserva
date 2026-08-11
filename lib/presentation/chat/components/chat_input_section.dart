import 'package:flutter/material.dart';

class ChatInputSection extends StatefulWidget {
  final Function(String) onSend;
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
  final _textController = TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_updateTextState);
  }

  void _updateTextState() {
    final hasText = _textController.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() {
        _hasText = hasText;
      });
    }
  }

  void _handleSend() {
    final text = _textController.text.trim();
    if (text.isNotEmpty && !widget.isSending) {
      widget.onSend(text);
      _textController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 8.0),
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E20),
        border: Border(
          top: BorderSide(color: Color(0xFF2D2D30), width: 1.0),
        ),
      ),
      child: SafeArea(
        child: Row(
          children: [
            // 1. Pulsante Allegati (+) storico ripristinato
            IconButton(
              icon: const Icon(Icons.add, color: Colors.white70, size: 26),
              onPressed: widget.isSending 
                  ? null 
                  : () {
                      showModalBottomSheet(
                        context: context,
                        backgroundColor: const Color(0xFF1E1E20),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                        ),
                        builder: (context) => SafeArea(
                          child: Wrap(
                            children: [
                              ListTile(
                                leading: const Icon(Icons.image, color: Colors.blueAccent),
                                title: const Text('Invia Immagine', style: TextStyle(color: Colors.white)),
                                onTap: () => Navigator.pop(context),
                              ),
                              ListTile(
                                leading: const Icon(Icons.insert_drive_file, color: Colors.green),
                                title: const Text('Allega Documento', style: TextStyle(color: Colors.white)),
                                onTap: () => Navigator.pop(context),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
            ),
            
            // 2. Campo di Testo auto-estensibile
            Expanded(
              child: TextField(
                controller: _textController,
                maxLines: 5,
                minLines: 1,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                cursorColor: Colors.blueAccent,
                decoration: InputDecoration(
                  hintText: 'Scrivi un messaggio...',
                  hintStyle: const TextStyle(color: Colors.white38, fontSize: 15),
                  filled: true,
                  fillColor: const Color(0xFF2A2A2C),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24.0),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            
            // 3. Pulsante Vocale (Inibito se sta già inviando)
            IconButton(
              icon: Icon(
                Icons.mic, 
                color: widget.isSending ? Colors.white24 : Colors.white70,
                size: 24,
              ),
              onPressed: widget.isSending ? null : widget.onVoicePressed,
            ),
            
            // 4. Pulsante Invia Dinamico / Spinner di caricamento inferenza
            widget.isSending
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12.0),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                      ),
                    ),
                  )
                : IconButton(
                    icon: Icon(
                      Icons.send,
                      color: _hasText ? Colors.blueAccent : Colors.white38,
                      size: 24,
                    ),
                    onPressed: _hasText ? _handleSend : null,
                  ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _textController.removeListener(_updateTextState);
    _textController.dispose();
    super.dispose();
  }
}
