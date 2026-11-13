import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/features/computer_use/computer_use_game_catalog.dart';

void main() {
  test('Car Jam QA link always points to the real Ladaneta Play listing', () {
    final url = ComputerUseGameCatalog.carJamPlayStoreUri;
    expect(url.scheme, 'https');
    expect(url.host, 'play.google.com');
    expect(url.path, '/store/apps/details');
    expect(url.queryParameters,
        <String, String>{'id': 'car.parking.jam.solver.puzzle.games'});
    expect(ComputerUseGameCatalog.carJamPackageId,
        'car.parking.jam.solver.puzzle.games');
    expect(ComputerUseGameCatalog.carJamDeveloper, 'Ladaneta Games');
  });
}
