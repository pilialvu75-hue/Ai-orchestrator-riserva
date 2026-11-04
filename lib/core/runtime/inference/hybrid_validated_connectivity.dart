import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Read-only Android system connectivity snapshot for opt-in HYBRID routing.
///
/// Android returns a validated default network using ConnectivityManager,
/// without a DNS lookup, HTTP probe, foreground service or background timer.
/// This signals general internet availability, *not* that a specific Cloud
/// provider is reachable. Provider errors are handled separately by relay.
///
/// Other platforms and missing/failed native bridges fail closed (false).
/// They require a dedicated trusted implementation before enabling Cloud
/// routing through the checkpoint relay on those platforms.
final class HybridValidatedConnectivity {
  const HybridValidatedConnectivity({
    MethodChannel channel =
        const MethodChannel('com.aiorchestrator/hybrid_connectivity'),
    TargetPlatform? platformOverride,
  })  : _channel = channel,
        _platformOverride = platformOverride;

  final MethodChannel _channel;
  final TargetPlatform? _platformOverride;

  /// Called on demand at a planned checkpoint boundary, never polled.
  Future<bool> isNetworkAvailable() async {
    if (kIsWeb ||
        (_platformOverride ?? defaultTargetPlatform) !=
            TargetPlatform.android) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('hasValidatedInternet') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
