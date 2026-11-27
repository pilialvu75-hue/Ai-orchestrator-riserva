/// User decision for this request only; never persisted as a preference.
enum WindowsMemoryChoice { cancel, retry, tryAnyway, reduced }

class WindowsMemoryReview {
  const WindowsMemoryReview({
    required this.modelBytes,
    this.availableRamBytes,
    this.availableVramBytes,
    required this.canAttempt,
  });
  final int modelBytes;
  final int? availableRamBytes, availableVramBytes;
  // True only when a measured reduced-reserve plan fits.
  final bool canAttempt;
}
