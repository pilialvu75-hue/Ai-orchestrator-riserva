/// Trusted QA app catalog. Never build Store URLs or Android package names
/// from untrusted model text. Opening the Store is a user-gesture-only flow;
/// installation is always completed by the owner in Google Play.
abstract final class ComputerUseGameCatalog {
  static const String carJamName = 'Car Jam Solver: Traffic Jam';
  static const String carJamDeveloper = 'Ladaneta Games';
  static const String carJamPackageId =
      'car.parking.jam.solver.puzzle.games';

  static Uri get carJamPlayStoreUri => Uri.https(
        'play.google.com',
        '/store/apps/details',
        const <String, String>{'id': carJamPackageId},
      );
}
