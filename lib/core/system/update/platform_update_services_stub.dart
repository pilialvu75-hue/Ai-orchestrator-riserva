import 'package:get_it/get_it.dart';

Future<void> configurePlatformUpdateServices(
  GetIt sl, {
  required String currentVersion,
}) async {
  // No-op for non-IO targets (for example Flutter Web).
}
