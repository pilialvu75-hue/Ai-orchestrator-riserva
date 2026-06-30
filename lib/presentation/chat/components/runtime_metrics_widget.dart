import 'package:ai_orchestrator/core/runtime/inference/local_runtime_status.dart';
import 'package:flutter/material.dart';

class RuntimeMetricsWidget extends StatelessWidget {
  const RuntimeMetricsWidget({
    super.key,
    required this.runtimeState,
    required this.voiceEngineActive,
    required this.gpuAccelerationActive,
    required this.gpuBackend,
    required this.runtimeModeName,
    this.additionalMetrics = const <Widget>[],
    this.onClose,
  });

  final LocalRuntimeState runtimeState;
  final bool voiceEngineActive;
  final bool gpuAccelerationActive;
  final String gpuBackend;
  final String runtimeModeName;
  final List<Widget> additionalMetrics;
  final VoidCallback? onClose;

  Color _statusColor() {
    switch (runtimeState.status) {
      case LocalRuntimeStatus.inferencing:
      case LocalRuntimeStatus.streaming:
      case LocalRuntimeStatus.ready:
        return const Color(0xFF4ADE80);
      case LocalRuntimeStatus.loading:
      case LocalRuntimeStatus.tokenizing:
        return const Color(0xFFF9A826);
      case LocalRuntimeStatus.failed:
      case LocalRuntimeStatus.ffiMissing:
      case LocalRuntimeStatus.modelMissing:
      case LocalRuntimeStatus.runtimeUnavailable:
        return const Color(0xFFFF8A80);
      case LocalRuntimeStatus.completed:
      case LocalRuntimeStatus.stalled:
      case LocalRuntimeStatus.timedOut:
      case LocalRuntimeStatus.uninitialized:
        return Colors.white38;
    }
  }

  @override
  Widget build(BuildContext context) {
    final runtimeMessage = runtimeState.message?.trim();
    final statusColor = _statusColor();
    final isRuntimeReady = runtimeState.status != LocalRuntimeStatus.ffiMissing &&
        runtimeState.status != LocalRuntimeStatus.modelMissing &&
        runtimeState.status != LocalRuntimeStatus.runtimeUnavailable;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF090D14).withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'RUNTIME METRICS',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    splashRadius: 16,
                    onPressed: onClose,
                    icon: const Icon(Icons.close, color: Colors.white70, size: 16),
                  ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.24),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${runtimeState.status.name.toUpperCase()} • $runtimeModeName',
                style: TextStyle(
                  color: statusColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Status: ${runtimeState.status.name}',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            Text(
              'Tokens: ${runtimeState.tokensGenerated}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            Text(
              'Elapsed: ${runtimeState.elapsed.inSeconds}s',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const Divider(height: 16, thickness: 0.5),
            Text(
              'Local Runtime: ${isRuntimeReady ? 'ON' : 'OFF'}',
              style: TextStyle(
                color: isRuntimeReady
                    ? const Color(0xFF4ADE80)
                    : const Color(0xFFFF8A80),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              'Voice Engine: ${voiceEngineActive ? 'ON' : 'OFF'}',
              style: TextStyle(
                color: voiceEngineActive
                    ? const Color(0xFF4ADE80)
                    : const Color(0xFFFF8A80),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              'GPU Backend: ${gpuBackend.toUpperCase()}',
              style: TextStyle(
                color: gpuAccelerationActive ? const Color(0xFF4ADE80) : Colors.white38,
                fontSize: 11,
              ),
            ),
            if (runtimeMessage != null && runtimeMessage.isNotEmpty) ...[
              const Divider(height: 16, thickness: 0.5),
              Text(
                runtimeMessage,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ],
            if (additionalMetrics.isNotEmpty) ...[
              const Divider(height: 16, thickness: 0.5),
              ...additionalMetrics,
            ],
          ],
        ),
      ),
    );
  }
}
