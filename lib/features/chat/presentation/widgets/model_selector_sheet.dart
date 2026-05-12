import 'package:flutter/material.dart';

class ModelSelectorSheet extends StatelessWidget {
  const ModelSelectorSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.all(20),
      child: const Text(
        'Provider routing is automatic. Local AI remains primary and cloud acceleration is selected dynamically.',
        style: TextStyle(color: Colors.white70),
      ),
    );
  }
}
