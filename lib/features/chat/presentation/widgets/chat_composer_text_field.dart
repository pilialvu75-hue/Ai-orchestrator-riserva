import 'package:flutter/material.dart';

/// Shared multiline editor. ChatComposerLayout gives long drafts extra
/// horizontal space on narrow screens, without changing the original
/// five-line input behavior or mutating the controller's text.
class ChatComposerTextField extends StatelessWidget {
  const ChatComposerTextField({
    super.key,
    required this.controller,
    required this.enabled,
    required this.autofocus,
    required this.hintText,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool autofocus;
  final String hintText;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      enabled: enabled,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
      ),
      minLines: 1,
      maxLines: 5,
      textInputAction: TextInputAction.newline,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(color: Colors.white38),
        isDense: true,
        border: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 12,
        ),
      ),
      onSubmitted: onSubmitted,
    );
  }
}
