import 'package:flutter/material.dart';

/// Two visible lines at most, including with large accessibility text.
/// Longer dictations and pasted drafts scroll INSIDE the editor instead of
/// expanding the composer over the conversation. This widget never truncates
/// or mutates the text stored in [controller].
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
        fontSize: 15,
        height: 1.3,
      ),
      minLines: 1,
      maxLines: 2,
      scrollPhysics: const ClampingScrollPhysics(),
      textInputAction: TextInputAction.newline,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(color: Colors.white38),
        isDense: true,
        border: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: 8,
        ),
      ),
      onSubmitted: onSubmitted,
    );
  }
}
