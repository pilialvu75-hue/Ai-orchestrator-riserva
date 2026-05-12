// lib/native/platform/bixby_handler.dart
import 'package:dartz/dartz.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform;

import 'package:ai_orchestrator/core/error/failures.dart';

/// Handler per Bixby (solo Android)
class BixbyHandler {
  const BixbyHandler();

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  // Tutte le funzioni restituiscono errore su piattaforme non-Android
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
      return const Left(IntentFailure('Bixby non supportato su questa piattaforma (Windows / iOS / macOS / Linux)'));
    }
    return const Left(IntentFailure('Bixby non configurato'));
  }
}
