import 'package:flutter/material.dart';

class ChatAppearanceViewModel extends ChangeNotifier {
  bool _showMetrics = false;
  bool _debugLabOpen = false;
  double _textScale = 1.0;
  double _assistantTextSize = 14.0;
  int _secretClickCount = 0;

  // Getter per l'esposizione controllata dello stato alla UI
  bool get showMetrics => _showMetrics;
  bool get debugLabOpen => _debugLabOpen;
  double get textScale => _textScale;
  double get assistantTextSize => _assistantTextSize;

  void toggleMetrics() {
    _showMetrics = !_showMetrics;
    notifyListeners();
  }

  void setMetricsVisibility(bool visible) {
    _showMetrics = visible;
    notifyListeners();
  }

  void closeDebugLab() {
    _debugLabOpen = false;
    notifyListeners();
  }

  void toggleMetricsFromLab() {
    _showMetrics = !_showMetrics;
    _debugLabOpen = false;
    notifyListeners();
  }

  void updateTextScale(double scale) {
    _textScale = scale;
    notifyListeners();
  }

  void updateFontSize(double size) {
    _assistantTextSize = size;
    notifyListeners();
  }

  /// Gestisce il pattern di sblocco a 7 click per il Developer Lab
  void handleSecretPatternClick() {
    _secretClickCount++;
    if (_secretClickCount >= 7) {
      _secretClickCount = 0;
      _debugLabOpen = !_debugLabOpen;
    }
    notifyListeners();
  }
}
