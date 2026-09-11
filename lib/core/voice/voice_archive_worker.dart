import 'dart:isolate';
import 'package:archive/archive_io.dart';

/// Keep the closure in a scope containing only transferable path strings.
/// The caller may own timers, UI callbacks, Dio and open native resources.
Future<void> extractVoiceArchiveInBackground(
  String archivePath,
  String destinationPath,
) {
  return Isolate.run(() => extractFileToDisk(archivePath, destinationPath));
}
