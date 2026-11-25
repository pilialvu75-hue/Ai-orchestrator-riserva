import 'package:flutter/foundation.dart';
import 'package:ai_orchestrator/core/runtime/inference/resident_completion_runtime.dart';

/// Presentation-only telemetry; never controls inference or fallback.
class WindowsGenerationMetrics extends ChangeNotifier {
  static final instance = WindowsGenerationMetrics();

  int _sequence = 0;
  Stopwatch? _clock;
  String? route;
  String phase = 'idle';
  int? firstTextMs;
  ResidentGenerationMetrics? terminal;
  int? get elapsedMs => _clock?.elapsedMilliseconds;

  /// A competing request cannot replace a generation already being observed.
  int? begin() {
    if (phase == 'preparing' || phase == 'streaming') return null;
    _sequence++;
    _clock = Stopwatch()..start();
    route = null;
    phase = 'preparing';
    firstTextMs = null;
    terminal = null;
    notifyListeners();
    return _sequence;
  }

  void selectRoute(int id, String value) {
    if (id != _sequence || phase != 'preparing') return;
    route = value;
    notifyListeners();
  }

  void firstText(int id) {
    if (id != _sequence || phase != 'preparing') return;
    firstTextMs = elapsedMs;
    phase = 'streaming';
    notifyListeners();
  }

  void finish(int id, {required bool success, ResidentGenerationMetrics? stats}) {
    if (id != _sequence ||
        (phase != 'preparing' && phase != 'streaming')) return;
    _clock?.stop();
    phase = success ? 'completed' : 'interrupted';
    terminal = success ? stats : null;
    notifyListeners();
  }
}
