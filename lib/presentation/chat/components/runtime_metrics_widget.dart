import 'package:flutter/material.dart';

class RuntimeMetricsWidget extends StatelessWidget {
  final dynamic monitorState; // Mantenuto dynamic in Fase 1 per riflettere l'oggetto del monitor legacy
  final VoidCallback onClose;

  const RuntimeMetricsWidget({
    super.key,
    required this.monitorState,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 16.0,
      left: 16.0,
      right: 16.0,
      child: Card(
        elevation: 6.0,
        color: Theme.of(context).alignment == null 
            ? Colors.black87 
            : Theme.of(context).cardColor.withOpacity(0.95),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12.0),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.analytics_outlined, size: 20, color: Colors.blueAccent),
                      SizedBox(width: 8),
                      Text(
                        'Metrics Lab',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onClose,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: 'Chiudi Overlay',
                  ),
                ],
              ),
              const Divider(height: 16, thickness: 0.5),
              // Consuma le proprietà native del monitor ereditate direttamente dal file monolitico
              Text(
                'Stato Core: ${monitorState?.status?.toString().split('.').last ?? 'Inattivo'}',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 6),
              Text(
                'Token Generati: ${monitorState?.tokensGenerated ?? 0}',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 6),
              Text(
                'Tempo di Esecuzione: ${monitorState?.elapsed?.toString() ?? '0s'}',
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
