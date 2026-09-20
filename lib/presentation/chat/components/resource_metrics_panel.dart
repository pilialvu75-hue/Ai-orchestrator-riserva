import 'package:flutter/material.dart';
import 'package:ai_orchestrator/core/runtime/inference/resource_monitor.dart';

class ResourceMetricsPanel extends StatefulWidget {
  const ResourceMetricsPanel({super.key});
  @override
  State<ResourceMetricsPanel> createState() => _ResourceMetricsPanelState();
}

class _ResourceMetricsPanelState extends State<ResourceMetricsPanel> {
  final monitor = ResourceMonitor.instance;
  @override
  void initState() {
    super.initState();
    monitor.retain();
  }

  @override
  void dispose() {
    monitor.release();
    super.dispose();
  }

  String mib(int? bytes) =>
      bytes == null ? 'n/d' : '${(bytes / 1048576).round()} MiB';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: monitor,
    builder: (context, _) {
      final ram = monitor.latest;
      final layers = monitor.native['gpu_layers'];
      final gpu = layers == null || layers < 0
          ? 'assegnazione n/d'
          : layers == 0
          ? '0 layer (CPU)'
          : '$layers layer (report nativo)';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children:
            [
                  const Divider(color: Colors.white24),
        Text('Sessione nativa: ${monitor.native['context'] == null ? 'non rilevata' : 'caricata'}'),
                  Text(
                    'RAM libera: ${mib(ram?.availableBytes)} / ${mib(ram?.totalBytes)}',
                  ),
                  Text('App RSS: ${mib(ram?.rssBytes)}'),
                  Text('Heap nativo: ${mib(ram?.nativeHeapBytes)}'),
                  Text(
                    'Pressione: ${ram == null
                        ? 'n/d'
                        : ram.critical
                        ? 'CRITICA'
                        : ram.pressured
                        ? 'alta'
                        : 'normale'}',
                    style: TextStyle(
                      color: ram?.critical == true
                          ? Colors.redAccent
                          : Colors.white70,
                    ),
                  ),
                  Text('GPU: $gpu'),
                  const Text('GPU utilizzo / memoria: n/d'),
                  Text(
                    'Decode completati: ${monitor.native['decode_calls'] ?? 'n/d'}',
                  ),
                  Text(
                    'Contesto / batch / microbatch: '
                    '${monitor.native['context'] ?? '-'} / '
                    '${monitor.native['batch'] ?? '-'} / '
                    '${monitor.native['micro_batch'] ?? '-'}',
                  ),
                  const Text('Campioni ogni 2 s • GPU % non esposta'),
                ]
                .map(
                  (child) => DefaultTextStyle(
                    style: const TextStyle(color: Colors.white70, fontSize: 10),
                    child: child,
                  ),
                )
                .toList(),
      );
    },
  );
}
