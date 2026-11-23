import 'package:flutter/material.dart';

/// Keeps the chat composer above Android's IME when the Scaffold has
/// resizeToAvoidBottomInset disabled. Desktop remains completely unaffected.
///
/// ChatInputBar already owns its SafeArea; this wrapper only adds the
/// *keyboard* displacement, avoiding a second navigation-bar inset.
class AndroidKeyboardAwareComposer extends StatelessWidget {
  const AndroidKeyboardAwareComposer({
    super.key,
    required this.child,
    required this.enabled,
  });

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      key: const Key('android-chat-composer-keyboard-inset'),
      padding: EdgeInsets.only(bottom: keyboardHeight),
      child: child,
    );
  }
}
