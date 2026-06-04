part of '../../runtime_core.dart';


class _AndroidFfiRuntimeDiagnosticsService {
  _AndroidFfiRuntimeDiagnosticsService(this._owner);

  final AndroidFfiRuntimeProvider _owner;

  String runtimeStatusSummary() {
    final runtimeStatus = _owner.monitor.state.status.name;
    final verificationStatus = _owner.verificationMonitor.state.phase.name;
    return 'runtime_status=$runtimeStatus verification_status=$verificationStatus';
  }
}
