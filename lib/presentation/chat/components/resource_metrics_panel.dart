import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:ai_orchestrator/core/runtime/inference/resource_monitor.dart';
import 'package:ai_orchestrator/core/runtime/inference/windows_generation_metrics.dart';
import 'package:ai_orchestrator/core/runtime/inference/windows_engine_process_tracker.dart';
import 'package:ai_orchestrator/core/runtime/inference/windows_gpu_metrics.dart';

class ResourceMetricsPanel extends StatefulWidget {
  const ResourceMetricsPanel({super.key});
  @override
  State<ResourceMetricsPanel> createState() => _ResourceMetricsPanelState();
}

class _ResourceMetricsPanelState extends State<ResourceMetricsPanel> {
  final monitor = ResourceMonitor.instance;
  final gpuMonitor = WindowsGpuMetrics.instance;
  bool _gpuRetained = false;
  @override
  void initState() {
    super.initState();
    monitor.retain();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      gpuMonitor.retain();
      _gpuRetained = true;
    }
  }

  @override
  void dispose() {
    if (_gpuRetained) gpuMonitor.release();
    monitor.release();
    super.dispose();
  }

  String mib(int? bytes) =>
      bytes == null ? 'n/d' : '${(bytes / 1048576).round()} MiB';
  String percent(double? value) => value == null ? 'n/d' : '${value.toStringAsFixed(1)}%';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([
          monitor, WindowsGenerationMetrics.instance, WindowsEngineProcessTracker.instance,
          if (_gpuRetained) gpuMonitor,
        ]),
        builder: (context, _) {
          final ram = monitor.latest;
          final generation = WindowsGenerationMetrics.instance;
          final engine = ram?.belongsTo(WindowsEngineProcessTracker.instance.current) == true ? ram : null;
          final time = ram?.timestamp;
          final sampleTime = time == null
              ? 'n/d'
              : '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
          final pressure = switch (ram?.pressure) {
            'critical' => 'CRITICA',
            'high' => 'alta',
            'normal' => 'normale',
            _ => 'n/d',
          };
          final layers = monitor.native['gpu_layers'];
          final gpu = layers == null || layers < 0
              ? 'assegnazione n/d'
              : layers == 0
                  ? '0 layer (CPU)'
                  : '$layers layer (report nativo)';
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(color: Colors.white24),
              Text(
                  'Sessione nativa: ${monitor.native['context'] == null ? 'non rilevata' : 'caricata'}'),
              Text(
                'RAM libera: ${mib(ram?.availableBytes)} / ${mib(ram?.totalBytes)}',
              ),
              Text('Soglia RAM Android: ${mib(ram?.thresholdBytes)}'),
              if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows)
                Text('CPU sistema: ${ram?.systemCpuPercent?.toStringAsFixed(1) ?? 'n/d'}${ram?.systemCpuPercent == null ? '' : '%'}'),
              Text('App RSS: ${mib(ram?.rssBytes)}'),
              if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) ...[
                Text('CPU AIVEXUS: ${percent(ram?.appCpuPercent)}'),
                Text('PID motore: ${engine?.enginePid ?? 'n/d'}'),
                Text('CPU motore: ${percent(engine?.engineCpuPercent)}'),
                Text('RAM motore RSS: ${mib(engine?.engineRssBytes)}'),
                Text('Ultima inferenza LOCAL: ${generation.phase}'),
                Text('Percorso selezionato: ${generation.route ?? 'n/d'}'),
                Text('Durata: ${generation.elapsedMs ?? 'n/d'} ms'),
                Text('Primo testo visibile: ${generation.firstTextMs ?? 'n/d'} ms'),
                Text('Token nativi: ${generation.terminal?.generatedTokens ?? 'n/d'}'),
                Text('Token/s nativi: ${generation.terminal?.tokensPerSecond?.toStringAsFixed(2) ?? 'n/d'}'),
                Text('Decodifica: ${generation.terminal?.decodeMilliseconds?.toStringAsFixed(1) ?? 'n/d'} ms'),
              ],
              Text('Heap nativo: ${mib(ram?.nativeHeapBytes)}'),
              Text(
                'Pressione: $pressure',
                style: TextStyle(
                  color:
                      ram?.critical == true ? Colors.redAccent : Colors.white70,
                ),
              ),
              Text('GPU: $gpu'),
              if (_gpuRetained && gpuMonitor.latest.isNotEmpty) ...[
                const Text('NVIDIA • intera scheda, non solo AIVEXUS'),
                for (final device in gpuMonitor.latest) ...[
                  Text('GPU ${device.index}: ${device.name}'),
                  Text('Utilizzo GPU: ${percent(device.utilizationPercent?.toDouble())}'),
                  Text('VRAM: ${device.usedMiB ?? 'n/d'} / ${device.totalMiB ?? 'n/d'} MiB'),
                ],
              ] else
                const Text('GPU utilizzo / memoria: n/d'),
              if (_gpuRetained && gpuMonitor.wddmLatest.isNotEmpty) ...[
                const Text('Windows WDDM • memoria per adattatore (non sommare a NVIDIA)'),
                for (final (index, adapter) in gpuMonitor.wddmLatest.indexed) ...[
                  Text('Adattatore WDDM ${index + 1} (${adapter.adapterId})'),
                  Text('Memoria dedicata: ${mib(adapter.dedicatedBytes)}'),
                  Text('Memoria condivisa: ${mib(adapter.sharedBytes)}'),
                ],
              ],
              Text(
                'Decode completati: ${monitor.native['decode_calls'] ?? 'n/d'}',
              ),
              Text(
                'Contesto / batch / microbatch: '
                '${monitor.native['context'] ?? '-'} / '
                '${monitor.native['batch'] ?? '-'} / '
                '${monitor.native['micro_batch'] ?? '-'}',
              ),
              Text('Ultimo campione: $sampleTime'),
              Text(_gpuRetained ? 'CPU/RAM ogni 2 s • GPU ogni 5 s' : 'Campioni ogni 2 s • GPU % non esposta'),
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
