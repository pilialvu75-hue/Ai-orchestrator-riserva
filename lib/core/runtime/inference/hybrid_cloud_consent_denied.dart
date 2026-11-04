/// A rejected Cloud data disclosure must terminate routing without failover.
final class HybridCloudConsentDenied implements Exception {
  const HybridCloudConsentDenied();

  @override
  String toString() => 'HybridCloudConsentDenied: no approved disclosure';
}
