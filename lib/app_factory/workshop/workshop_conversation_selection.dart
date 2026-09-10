import 'package:flutter/material.dart';

/// Selection boundary owned by the Cantiere presentation layer.
///
/// Wrapping the conversational surface in a [SelectionArea] lets the owner
/// select and copy complete Workshop responses with the platform-native text
/// selection controls. It deliberately does not depend on Assistant chat UI.
final class WorkshopConversationSelection extends StatelessWidget {
  const WorkshopConversationSelection({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: child,
    );
  }
}
