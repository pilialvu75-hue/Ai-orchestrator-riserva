import 'package:ai_orchestrator/features/chat/presentation/debug/debug_lab_controller.dart';
import 'package:flutter/material.dart';

/// A neutral header accent with no ordinary menu action. Debug Lab is
/// deliberately accessible only through the existing seven-rapid-tap pattern.
class DebugLabTapTarget extends StatelessWidget {
  const DebugLabTapTarget({super.key, required this.controller});

  final DebugLabController controller;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('aivexus-header-accent'),
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: controller.registerHeaderTap,
      child: const SizedBox(
        width: 28,
        height: 48,
        child: Center(
          child: Icon(Icons.auto_awesome, size: 17, color: Colors.white38),
        ),
      ),
    );
  }
}
