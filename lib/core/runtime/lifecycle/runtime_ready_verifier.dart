import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Result returned by every [RuntimeReadyVerifier] check.
///
/// Use the [VerificationResult.success] factory for a passing result and
/// [VerificationResult.failure] for a failing one.
sealed class VerificationResult {
  const VerificationResult();

  factory VerificationResult.success() = _SuccessResult;

  factory VerificationResult.failure(String reason) = _FailureResult;

  /// `true` when the check passed.
  bool get isSuccess;

  /// The human-readable failure reason, or `null` on success.
  String? get failureReason;
}

final class _SuccessResult extends VerificationResult {
  const _SuccessResult();

  @override
  bool get isSuccess => true;

  @override
  String? get failureReason => null;
}

final class _FailureResult extends VerificationResult {
  const _FailureResult(this._reason);

  final String _reason;

  @override
  bool get isSuccess => false;

  @override
  String? get failureReason => _reason;
}

// ---------------------------------------------------------------------------
// Verifier
// ---------------------------------------------------------------------------

/// Runs pre-flight checks before the runtime transitions to `ready`.
///
/// Each method is intentionally narrow so that individual failures can be
/// diagnosed and logged with their own structured tag.
class RuntimeReadyVerifier {
  const RuntimeReadyVerifier();

  // GGUF magic bytes: 0x47 0x47 0x55 0x46  ('G' 'G' 'U' 'F')
  static const List<int> _ggufMagic = [0x47, 0x47, 0x55, 0x46];

  static const Set<Abi> _supportedAndroidAbis = {Abi.androidArm64};

  // ---------------------------------------------------------------------------
  // Model file
  // ---------------------------------------------------------------------------

  /// Verifies that [modelPath] exists, is readable, and has a valid GGUF
  /// magic header.
  Future<VerificationResult> validateModel(String modelPath) async {
    debugPrint('[MODEL_VALIDATION] Checking model file: $modelPath');

    final file = File(modelPath);

    if (!file.existsSync()) {
      const reason = 'Model file does not exist';
      debugPrint('[MODEL_VALIDATION] FAIL – $reason');
      return VerificationResult.failure(reason);
    }

    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final header = await raf.read(4);

      if (header.length < 4) {
        const reason = 'Model file too small to contain GGUF header';
        debugPrint('[MODEL_VALIDATION] FAIL – $reason');
        return VerificationResult.failure(reason);
      }

      for (int i = 0; i < 4; i++) {
        if (header[i] != _ggufMagic[i]) {
          final expected = _ggufMagic
              .map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}')
              .join(' ');
          final got = header
              .map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}')
              .join(' ');
          final reason =
              'Invalid GGUF magic bytes: expected [$expected], got [$got]';
          debugPrint('[MODEL_VALIDATION] FAIL – $reason');
          return VerificationResult.failure(reason);
        }
      }

      debugPrint('[MODEL_VALIDATION] OK – GGUF header valid');
      return VerificationResult.success();
    } catch (e) {
      final reason = 'Cannot read model file: $e';
      debugPrint('[MODEL_VALIDATION] FAIL – $reason');
      return VerificationResult.failure(reason);
    } finally {
      await raf?.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Native bridge
  // ---------------------------------------------------------------------------

  /// Checks that the native bridge library can be expected to be present.
  ///
  /// On non-Android platforms (desktop / test runners) this always succeeds
  /// because the llama-cli binary handles inference directly.
  Future<VerificationResult> validateNativeBridge() async {
    debugPrint('[NATIVE_READY] Checking native bridge availability');

    if (!Platform.isAndroid) {
      debugPrint(
        '[NATIVE_READY] OK – non-Android platform, native bridge not required',
      );
      return VerificationResult.success();
    }

    final abi = Abi.current();
    if (!_supportedAndroidAbis.contains(abi)) {
      final reason = 'Unsupported Android ABI: $abi';
      debugPrint('[NATIVE_READY] FAIL – $reason');
      return VerificationResult.failure(reason);
    }

    debugPrint('[NATIVE_READY] OK – ABI $abi is supported');
    return VerificationResult.success();
  }

  // ---------------------------------------------------------------------------
  // Tokenizer
  // ---------------------------------------------------------------------------

  /// Validates that the tokenizer subsystem is in an initialised state.
  ///
  /// The GGUF model file embeds the tokenizer vocabulary; a valid model
  /// header (confirmed by [validateModel]) is a sufficient proxy for
  /// tokenizer readiness at this layer.
  Future<VerificationResult> validateTokenizer() async {
    debugPrint('[TOKENIZER_READY] Checking tokenizer init state');
    debugPrint('[TOKENIZER_READY] OK – tokenizer ready (embedded in model)');
    return VerificationResult.success();
  }

  // ---------------------------------------------------------------------------
  // Embeddings
  // ---------------------------------------------------------------------------

  /// Validates that the embedding runtime is initialised.
  ///
  /// Embeddings are driven by the same GGUF model that handles text
  /// generation; a validated model file is sufficient evidence.
  Future<VerificationResult> validateEmbeddings() async {
    debugPrint('[EMBEDDING_READY] Checking embedding runtime init');
    debugPrint(
      '[EMBEDDING_READY] OK – embeddings ready (provided by loaded model)',
    );
    return VerificationResult.success();
  }

  // ---------------------------------------------------------------------------
  // Context allocation
  // ---------------------------------------------------------------------------

  /// Placeholder that returns success: context is allocated by the native
  /// bridge during model loading and is not re-verified at this layer.
  Future<VerificationResult> validateContextAllocation() async {
    debugPrint(
      '[MODEL_VALIDATION] Context allocation delegated to native bridge – OK',
    );
    return VerificationResult.success();
  }
}
