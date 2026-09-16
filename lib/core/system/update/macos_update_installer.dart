import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

class MacosInstallerVerification {
  const MacosInstallerVerification({
    required this.valid,
    required this.exists,
    required this.sizeBytes,
    required this.sha256,
    required this.reason,
  });

  final bool valid;
  final bool exists;
  final int sizeBytes;
  final String? sha256;
  final String reason;
}

abstract interface class MacosUpdateInstallerPort {
  Future<String> download({
    required String url,
    required String fileName,
    required String finalPath,
    required String partialPath,
    required int expectedSizeBytes,
    required String expectedSha256,
    required void Function(int received, int total) onProgress,
  });

  Future<MacosInstallerVerification> verify({
    required String filePath,
    required int expectedSizeBytes,
    required String expectedSha256,
  });

  Future<bool> launch(String filePath);
}

class MacosUpdateInstaller implements MacosUpdateInstallerPort {
  MacosUpdateInstaller({
    Dio? dio,
    Future<bool> Function(String filePath)? launcher,
  })  : _dio = dio ?? Dio(),
        _launcher = launcher;

  final Dio _dio;
  final Future<bool> Function(String filePath)? _launcher;

  static const Duration _downloadTimeout = Duration(minutes: 15);

  @override
  Future<String> download({
    required String url,
    required String fileName,
    required String finalPath,
    required String partialPath,
    required int expectedSizeBytes,
    required String expectedSha256,
    required void Function(int received, int total) onProgress,
  }) async {
    _validateArtifactMetadata(
      url: url,
      fileName: fileName,
      expectedSizeBytes: expectedSizeBytes,
      expectedSha256: expectedSha256,
    );

    final finalFile = File(finalPath);
    if (await finalFile.exists()) {
      final existing = await verify(
        filePath: finalPath,
        expectedSizeBytes: expectedSizeBytes,
        expectedSha256: expectedSha256,
      );
      if (existing.valid) {
        onProgress(existing.sizeBytes, expectedSizeBytes);
        return finalPath;
      }
      await finalFile.delete();
    }

    final partialFile = File(partialPath);
    await partialFile.parent.create(recursive: true);
    final existingPartialBytes =
        await partialFile.exists() ? await partialFile.length() : 0;
    final headers = <String, dynamic>{};
    if (existingPartialBytes > 0) {
      headers[HttpHeaders.rangeHeader] = 'bytes=$existingPartialBytes-';
    }

    final response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        receiveTimeout: _downloadTimeout,
        headers: headers,
        validateStatus: (status) =>
            status != null &&
            (status == HttpStatus.ok || status == HttpStatus.partialContent),
      ),
    );

    final supportsResume = existingPartialBytes > 0 &&
        response.statusCode == HttpStatus.partialContent;
    final sink = partialFile.openWrite(
      mode: supportsResume ? FileMode.append : FileMode.write,
    );
    final reportedLength =
        int.tryParse(response.headers.value(Headers.contentLengthHeader) ?? '');
    final totalBytes = supportsResume
        ? existingPartialBytes + (reportedLength ?? 0)
        : (reportedLength ?? expectedSizeBytes);
    var receivedBytes = supportsResume ? existingPartialBytes : 0;

    try {
      final stream = response.data?.stream;
      if (stream == null) {
        throw StateError('macOS installer response body is empty.');
      }
      await for (final chunk in stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        onProgress(
          receivedBytes,
          totalBytes > 0 ? totalBytes : expectedSizeBytes,
        );
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    await partialFile.rename(finalPath);

    final verification = await verify(
      filePath: finalPath,
      expectedSizeBytes: expectedSizeBytes,
      expectedSha256: expectedSha256,
    );
    if (!verification.valid) {
      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      throw StateError(
        'Downloaded macOS installer failed verification: ${verification.reason}',
      );
    }
    onProgress(verification.sizeBytes, expectedSizeBytes);
    return finalPath;
  }

  @override
  Future<MacosInstallerVerification> verify({
    required String filePath,
    required int expectedSizeBytes,
    required String expectedSha256,
  }) async {
    final file = File(filePath);
    if (!filePath.toLowerCase().endsWith('.dmg')) {
      return const MacosInstallerVerification(
        valid: false,
        exists: false,
        sizeBytes: 0,
        sha256: null,
        reason: 'installer path is not a .dmg file',
      );
    }
    if (!await file.exists()) {
      return const MacosInstallerVerification(
        valid: false,
        exists: false,
        sizeBytes: 0,
        sha256: null,
        reason: 'installer file does not exist',
      );
    }

    final sizeBytes = await file.length();
    if (sizeBytes != expectedSizeBytes) {
      return MacosInstallerVerification(
        valid: false,
        exists: true,
        sizeBytes: sizeBytes,
        sha256: null,
        reason:
            'installer size mismatch: expected=$expectedSizeBytes actual=$sizeBytes',
      );
    }

    final digest = await sha256.bind(file.openRead()).first;
    final actualSha256 = digest.toString().toLowerCase();
    final normalizedExpected = expectedSha256.trim().toLowerCase();
    if (actualSha256 != normalizedExpected) {
      return MacosInstallerVerification(
        valid: false,
        exists: true,
        sizeBytes: sizeBytes,
        sha256: actualSha256,
        reason: 'installer SHA-256 mismatch',
      );
    }

    return MacosInstallerVerification(
      valid: true,
      exists: true,
      sizeBytes: sizeBytes,
      sha256: actualSha256,
      reason: 'ok',
    );
  }

  @override
  Future<bool> launch(String filePath) async {
    if (_launcher != null) {
      return _launcher(filePath);
    }
    if (!Platform.isMacOS) {
      return false;
    }
    final file = File(filePath);
    if (!await file.exists() || !filePath.toLowerCase().endsWith('.dmg')) {
      return false;
    }
    final result = await Process.run(
      '/usr/bin/open',
      <String>[filePath],
    );
    return result.exitCode == 0;
  }

  void _validateArtifactMetadata({
    required String url,
    required String fileName,
    required int expectedSizeBytes,
    required String expectedSha256,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        uri.host.isEmpty) {
      throw ArgumentError.value(url, 'url', 'Must be a valid HTTP(S) URL');
    }
    if (fileName.isEmpty ||
        fileName.contains('/') ||
        fileName.contains('\\') ||
        !fileName.toLowerCase().endsWith('.dmg')) {
      throw ArgumentError.value(
        fileName,
        'fileName',
        'Must be a safe .dmg filename',
      );
    }
    if (expectedSizeBytes <= 0) {
      throw ArgumentError.value(
        expectedSizeBytes,
        'expectedSizeBytes',
        'Must be greater than zero',
      );
    }
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(expectedSha256.trim())) {
      throw ArgumentError.value(
        expectedSha256,
        'expectedSha256',
        'Must be a 64-character hexadecimal SHA-256',
      );
    }
  }
}
