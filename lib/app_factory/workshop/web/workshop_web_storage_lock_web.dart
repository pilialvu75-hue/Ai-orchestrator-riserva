// Same Dart 3.4 compatibility floor as the existing browser audio adapter.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:js_interop';
import 'dart:js_util' as js_util;

/// A lock spans all cooperating Aivexus tabs on this origin. No localStorage
/// check-then-set imitation: browsers without Web Locks remain read-only.
Future<T> withWorkshopStorageLock<T>(
  String name,
  Future<T> Function() action,
) async {
  final navigator = html.window.navigator;
  if (!js_util.hasProperty(navigator, 'locks')) {
    throw UnsupportedError(
      'Salvataggio sicuro non disponibile in questo browser.',
    );
  }
  final locks = js_util.getProperty<Object?>(navigator, 'locks');
  if (locks == null) {
    throw UnsupportedError(
      'Salvataggio sicuro non disponibile in questo browser.',
    );
  }
  late T result;
  final promise = js_util.callMethod<Object>(locks, 'request', <Object?>[
    name,
    js.allowInterop((Object? _) {
      return (() async {
        result = await action();
        return null as JSAny?;
      })().toJS;
    }),
  ]);
  await js_util.promiseToFuture<Object?>(promise);
  return result;
}
