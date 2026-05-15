import 'dart:io';

import 'package:flutter/foundation.dart';

class IntegrityVerificationResult {
  const IntegrityVerificationResult({
    required this.isValid,
    required this.details,
  });

  final bool isValid;
  final String details;

  @override
  String toString() =>
      'IntegrityVerificationResult(isValid: $isValid, details: $details)';
}

class DownloadIntegrityVerifier {
  static const List<int> _ggufMagic = [0x47, 0x47, 0x55, 0x46];
  static const int _minFileSizeBytes = 4096;

  Future<IntegrityVerificationResult> verifyGgufFile(String filePath) async {
    debugPrint('[MODEL_VALIDATION] Verifying GGUF file: $filePath');

    final file = File(filePath);

    if (!file.existsSync()) {
      const details = 'File does not exist';
      debugPrint('[MODEL_VALIDATION] FAIL – $details');
      return IntegrityVerificationResult(isValid: false, details: details);
    }

    final fileSize = await file.length();
    if (fileSize <= _minFileSizeBytes) {
      final details =
          'File too small: $fileSize bytes (minimum: $_minFileSizeBytes)';
      debugPrint('[MODEL_VALIDATION] FAIL – $details');
      return IntegrityVerificationResult(isValid: false, details: details);
    }

    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final header = await raf.read(4);

      if (header.length < 4) {
        const details = 'Could not read 4-byte GGUF header';
        debugPrint('[MODEL_VALIDATION] FAIL – $details');
        return IntegrityVerificationResult(isValid: false, details: details);
      }

      for (int i = 0; i < 4; i++) {
        if (header[i] != _ggufMagic[i]) {
          final expected = _ggufMagic
              .map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}')
              .join(' ');
          final got = header
              .map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}')
              .join(' ');
          final details =
              'Invalid GGUF magic bytes: expected [$expected], got [$got]';
          debugPrint('[MODEL_VALIDATION] FAIL – $details');
          return IntegrityVerificationResult(isValid: false, details: details);
        }
      }
    } catch (e) {
      final details = 'Cannot read file: $e';
      debugPrint('[MODEL_VALIDATION] FAIL – $details');
      return IntegrityVerificationResult(isValid: false, details: details);
    } finally {
      await raf?.close();
    }

    const details = 'GGUF header valid, file size acceptable';
    debugPrint('[MODEL_VALIDATION] OK – $details');
    return const IntegrityVerificationResult(isValid: true, details: details);
  }

  Future<IntegrityVerificationResult> verifyFileSize(
    String filePath,
    int expectedBytes,
  ) async {
    debugPrint(
      '[MODEL_VALIDATION] Verifying file size: $filePath '
      '(expected: $expectedBytes bytes)',
    );

    final file = File(filePath);

    if (!file.existsSync()) {
      const details = 'File does not exist';
      debugPrint('[MODEL_VALIDATION] FAIL – $details');
      return IntegrityVerificationResult(isValid: false, details: details);
    }

    final actualBytes = await file.length();
    if (actualBytes != expectedBytes) {
      final details =
          'Size mismatch: expected $expectedBytes bytes, got $actualBytes bytes';
      debugPrint('[MODEL_VALIDATION] FAIL – $details');
      return IntegrityVerificationResult(isValid: false, details: details);
    }

    final details = 'File size matches: $actualBytes bytes';
    debugPrint('[MODEL_VALIDATION] OK – $details');
    return IntegrityVerificationResult(isValid: true, details: details);
  }
}
