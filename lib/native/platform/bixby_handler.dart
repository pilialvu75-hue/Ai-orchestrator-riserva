// lib/native/platform/bixby_handler.dart
import 'package:dartz/dartz.dart';

import 'package:ai_orchestrator/core/config/runtime/platform_capabilities.dart';
import 'package:ai_orchestrator/core/error/failures.dart';

/// Handler per Bixby (solo Android).
///
/// Platform availability is obtained from the shared capability boundary so
/// feature logic does not need raw Platform.isX checks.
class BixbyHandler {
  const BixbyHandler({
    AppPlatformCapabilities? capabilities,
  }) : _capabilities = capabilities;

  final AppPlatformCapabilities? _capabilities;

  AppPlatformCapabilities get _platform =>
      _capabilities ?? AppPlatformCapabilities.current();

  bool get _isAndroid => _platform.supportsAndroidIntents;

  // Tutte le funzioni restituiscono errore su piattaforme non-Android.
  Future<Either<Failure, bool>> setAlarm({
    required String label,
    required int hour,
    required int minute,
  }) async {
    if (!_isAndroid) {
      return const Left(IntentFailure('Bixby disponibile solo su Android'));
    }
    return const Left(IntentFailure('Bixby non configurato'));
  }

  Future<Either<Failure, bool>> toggleAirplaneMode() async {
    if (!_isAndroid) {
      return const Left(IntentFailure('Bixby disponibile solo su Android'));
    }
    return const Left(IntentFailure('Bixby non configurato'));
  }

  Future<Either<Failure, bool>> openWifiSettings() async {
    if (!_isAndroid) {
      return const Left(IntentFailure('Bixby disponibile solo su Android'));
    }
    return const Left(IntentFailure('Bixby non configurato'));
  }

  Future<Either<Failure, bool>> runRoutine(String routineName) async {
    if (!_isAndroid) {
      return const Left(IntentFailure('Bixby disponibile solo su Android'));
    }
    return const Left(IntentFailure('Bixby non configurato'));
  }

  Future<Either<Failure, String>> parseAndExecute(String command) async {
    if (!_isAndroid) {
      return Left(
        IntentFailure('Bixby non supportato su ' + _platform.label),
      );
    }
    return const Left(IntentFailure('Bixby non configurato'));
  }
}
