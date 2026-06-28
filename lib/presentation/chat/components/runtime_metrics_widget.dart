import 'package:flutter/material.dart';

class RuntimeMetricsWidget extends StatelessWidget {
  final dynamic monitorState;
  final bool voiceEngineActive;
  final bool gpuAccelerationActive;
  final String gpuBackend;
  final String runtimeModeName;
  final VoidCallback onClose;

  const RuntimeMetricsWidget({
    super.key,
    required this.monitorState,
    required this.voiceEngineActive,
    required this.gpuAccelerationActive,
    required this.gpuBackend,
    required this.runtimeModeName,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Positioned(
      top: 16.0,
      left: 16.0,
      right: 16.0,
      child: Card(
        elevation: 6.0,
        color: isDark ? Colors.black87 : Theme.of(context).cardColor.withValues(alpha: 0.95),
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
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
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
              const Divider(height: 16, thickness: 0.5),
              Text('Modalità Runtime: $runtimeModeName', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              Text('Accelerazione GPU: ${gpuAccelerationActive ? "Attiva ($gpuBackend)" : "Inattiva (CPU)"}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              Text('Motore Vocale ASR: ${voiceEngineActive ? "Pronto" : "Non Inizializzato"}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }
}
