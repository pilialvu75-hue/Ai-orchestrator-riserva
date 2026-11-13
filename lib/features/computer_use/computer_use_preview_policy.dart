/// Decides when a manual laboratory action may replace the last captured
/// frame. A passive target selection needs that exact capture for the next
/// tap; refreshing would display Aivexus rather than the observed app.
abstract final class ComputerUsePreviewPolicy {
  static bool shouldRefreshAfterAction(String? action) =>
      action != 'select_window_at';
}
