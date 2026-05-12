import 'package:flutter/foundation.dart';

class StartupTransitionController extends ChangeNotifier {
  bool _ready = false;

  bool get isReady => _ready;

  void markReady() {
    if (_ready) return;
    _ready = true;
    notifyListeners();
  }
}
