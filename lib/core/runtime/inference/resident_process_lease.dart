import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Only the inference child joins this job. Its handle is not inherited.
/// Windows kills the child even if the parent app crashes or is force-closed.
class ResidentProcessLease {
  ResidentProcessLease._(this._job);
  int _job;

  static ResidentProcessLease? attach(int processId) {
    if (!Platform.isWindows) return null;
    final job = CreateJobObject(nullptr, nullptr);
    if (job == 0) throw StateError('Cannot contain the local runtime process.');
    final info = calloc<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
    var process = 0;
    try {
      info.ref.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
      if (SetInformationJobObject(job, JobObjectExtendedLimitInformation,
          info.cast(), sizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>()) == 0) {
        throw StateError('Cannot configure local runtime lifetime.');
      }
      process = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, 0, processId);
      if (process == 0 || AssignProcessToJobObject(job, process) == 0) {
        throw StateError('Cannot contain the local runtime process.');
      }
      return ResidentProcessLease._(job);
    } catch (_) {
      CloseHandle(job);
      rethrow;
    } finally {
      if (process != 0) CloseHandle(process);
      calloc.free(info);
    }
  }

  void close() {
    if (_job == 0) return;
    CloseHandle(_job);
    _job = 0;
  }
}
