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

/// Resolves how a resumable HTTP response may interact with an existing
/// `.part` file. Keeping this policy pure makes Range handling independently
/// testable without creating another downloader.
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
    return DownloadResumeAction.restartFromZero;
  }

  return DownloadResumeAction.reject;
}
