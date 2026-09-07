/// Network lengths are exact; catalogue sizes are only estimates.
bool hasCompleteDownload({
  required int savedBytes,
  required int receivedBytes,
  required int? remoteTotal,
  required int? responseLength,
}) {
  if (savedBytes <= 0 || remoteTotal == null || remoteTotal <= 0) return false;
  if (savedBytes != remoteTotal) return false;
  return responseLength == null || receivedBytes == responseLength;
}

/// Detect legacy truncated files without treating approximate catalogue sizes
/// as exact HTTP lengths. This is a sanity check, not full GGUF validation.
bool isClearlyTruncatedModel(int actualBytes, int estimatedBytes) =>
    estimatedBytes > 0 && actualBytes < estimatedBytes * 0.90;

enum DownloadResumeAction {
  append,
  restartFromZero,
  promotePartial,
  reject,
}

/// Decides how an HTTP response must interact with an existing `.part` file.
///
/// This keeps the resumable-transfer rules independently testable:
/// - 206 may append only when Content-Range starts exactly at the local size
///   and exposes a positive total object length.
/// - 200 after a Range request means the server ignored Range, so the local
///   partial must be overwritten rather than appended.
/// - 416 promotes only a valid partial whose byte count exactly matches the
///   server's `bytes */total`; otherwise the stale/corrupt partial is restarted
///   from zero on the next request.
DownloadResumeAction resolveDownloadResumeAction({
  required int statusCode,
  required int existingBytes,
  required int? rangeStart,
  required int? rangeTotal,
  required int? rangeNotSatisfiableTotal,
  required bool partialIsValidGguf,
}) {
  if (statusCode == 416 && existingBytes > 0) {
    if (partialIsValidGguf &&
        rangeNotSatisfiableTotal != null &&
        rangeNotSatisfiableTotal == existingBytes) {
      return DownloadResumeAction.promotePartial;
    }
    return DownloadResumeAction.restartFromZero;
  }

  if (statusCode == 206) {
    if (existingBytes > 0 &&
        rangeStart == existingBytes &&
        rangeTotal != null &&
        rangeTotal > existingBytes) {
      return DownloadResumeAction.append;
    }
    return DownloadResumeAction.reject;
  }

  if (statusCode == 200) {
    return existingBytes > 0
        ? DownloadResumeAction.restartFromZero
        : DownloadResumeAction.restartFromZero;
  }

  return DownloadResumeAction.reject;
}
