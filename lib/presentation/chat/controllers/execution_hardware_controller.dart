import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class HardwareSnapshot {
  final bool gpuAccelerationActive;
  final String gpuBackend;

  const HardwareSnapshot({
    this.gpuAccelerationActive = false,
    this.gpuBackend = 'cpu',
  });
}

class ExecutionHardwareController extends ValueNotifier<HardwareSnapshot> {
  static const _mlcNativeChannel = MethodChannel('com.aiorchestrator/mlc_native');

  ExecutionHardwareController() : super(const HardwareSnapshot());

  /// Interroga l'infrastruttura nativa (Android NDK / Desktop) per verificare lo stato della GPU
  Future<void> updateHardwareStatus() async {
    var gpuActive = false;
    var gpuBackend = 'cpu';

    try {
      final nativeAvailable = await _mlcNativeChannel.invokeMethod<bool>('isMlcNativeAvailable');
      final backend = await _mlcNativeChannel.invokeMethod<String>('getMlcBackend');
      
      gpuBackend = (backend ?? 'cpu').trim();
      final normalizedBackend = gpuBackend.toLowerCase();
      
      gpuActive = nativeAvailable == true &&
          normalizedBackend.isNotEmpty &&
          normalizedBackend != 'cpu' &&
          normalizedBackend != 'fallback-llama';
    } on PlatformException {
      gpuActive = false;
      gpuBackend = 'unavailable';
    } on MissingPluginException {
      gpuActive = false;
      gpuBackend = 'unavailable';
    }

    // CORRETTO: Cambiati '=' in ':' per l'inizializzazione dei parametri nominali
    value = HardwareSnapshot(
      gpuAccelerationActive: gpuActive,
      gpuBackend: gpuBackend,
    );
  }
}
