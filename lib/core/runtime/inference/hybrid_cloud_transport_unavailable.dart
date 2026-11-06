/// No usable response from the exact consent-approved Cloud HTTP destination.
///
/// Typed exclusively at the native HTTP transport boundary: an HTTP 4xx/5xx
/// response, malformed JSON, quota, auth failure, or user refusal NEVER raises
/// this error. The exception contains no private request or credential data.
final class HybridCloudTransportUnavailable implements Exception {
  const HybridCloudTransportUnavailable();

  @override
  String toString() => 'HybridCloudTransportUnavailable';
}
