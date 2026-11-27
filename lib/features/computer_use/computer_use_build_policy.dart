/// Build-time gate for the experimental Computer Use laboratory.
/// Default CI, stable and other non-beta builds remain disabled. Authorized
/// beta publishers must explicitly compile this flag ON; user permissions
/// and manual session consent still apply.
///
/// This gate only exposes a manual lab. It does not register an autonomous
/// tool in the model, enable OS permissions or change any release setting.
abstract final class ComputerUseLabBuildPolicy {
  static const bool enabled = bool.fromEnvironment(
    'AIVEXUS_EXPERIMENTAL_COMPUTER_USE_QA',
    defaultValue: false,
  );
}
