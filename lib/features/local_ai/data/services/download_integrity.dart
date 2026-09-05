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
