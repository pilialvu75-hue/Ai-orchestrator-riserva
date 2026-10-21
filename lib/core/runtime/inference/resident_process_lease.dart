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
    final info = calloc<_ExtendedJobLimits>();
    var process = 0;
    try {
      info.ref.basic.limitFlags = 0x00002000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
      if (SetInformationJobObject(job, JobObjectExtendedLimitInformation,
          info.cast(), sizeOf<_ExtendedJobLimits>()) == 0) {
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

// Win32 5.15 exposes job APIs but not these structures. Layout follows winnt.h:
// https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-jobobject_extended_limit_information
final class _BasicJobLimits extends Struct {
  @Int64()
  external int processTime;
  @Int64()
  external int jobTime;
  @Uint32()
  external int limitFlags;
  @UintPtr()
  external int minimumWorkingSet;
  @UintPtr()
  external int maximumWorkingSet;
  @Uint32()
  external int activeProcessLimit;
  @UintPtr()
  external int affinity;
  @Uint32()
  external int priorityClass;
  @Uint32()
  external int schedulingClass;
}

final class _ExtendedJobLimits extends Struct {
  external _BasicJobLimits basic;
  @Array(6)
  external Array<Uint64> ioCounters;
  @UintPtr()
  external int processMemoryLimit;
  @UintPtr()
  external int jobMemoryLimit;
  @UintPtr()
  external int peakProcessMemory;
  @UintPtr()
  external int peakJobMemory;
}
