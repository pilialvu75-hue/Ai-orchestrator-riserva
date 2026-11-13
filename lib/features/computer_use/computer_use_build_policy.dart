/// Build-time gate for the experimental Computer Use laboratory.
/// Default production, stable, and beta builds MUST remain disabled unless
/// an explicitly authorized QA build opts in with --dart-define.
///
/// This gate only exposes a manual lab. It does not register an autonomous
/// tool in the model, enable OS permissions or change any release setting.
abstract final class ComputerUseLabBuildPolicy {
  static const bool enabled = bool.fromEnvironment(
    'AIVEXUS_EXPERIMENTAL_COMPUTER_USE_QA',
    defaultValue: false,
  );
}
