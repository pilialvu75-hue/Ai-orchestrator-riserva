/// User-intent class used by Cloud routing and spending policy.
///
/// This contract deliberately describes the task, not the selected provider or
/// execution backend. It is therefore safe to share between runtime settings
/// and the Cloud router without coupling either side to UI concerns.
enum CloudTaskClass {
  general,
  reasoning,
  coding,
}
