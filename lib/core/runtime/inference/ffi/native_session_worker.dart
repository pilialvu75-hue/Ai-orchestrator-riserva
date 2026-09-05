import 'dart:ffi';
import 'dart:isolate';

/// Native release joins the generation thread and can block until a decode
/// returns. Keep that wait off the UI isolate, while the caller still awaits
/// actual cleanup before reusing the runtime. Only send primitive values.
Future<void> releaseNativeSessionOffUi(
  int sessionId, {
  String libraryPath = 'libllama_bridge.so',
}) =>
    Isolate.run(() {
      final library = DynamicLibrary.open(libraryPath);
      final release = library.lookupFunction<Void Function(Int64),
          void Function(int)>('llb_release_session');
      release(sessionId);
    });
