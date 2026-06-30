import 'package:flutter/material.dart';
import 'package:ai_orchestrator/core/runtime/chat_ui_preferences_service.dart';

class ChatAppearanceViewModel extends ChangeNotifier {
  bool _showMetrics = false;
  bool _debugLabOpen = false;
  double _textScale = 1.0;
  AssistantMessageTextSize _assistantTextSize = AssistantMessageTextSize.medium;
  int _secretClickCount = 0;

  // Getter per l'esposizione controllata dello stato alla UI
  bool get showMetrics => _showMetrics;
  bool get debugLabOpen => _debugLabOpen;
  double get textScale => _textScale;
  AssistantMessageTextSize get assistantTextSize => _assistantTextSize;

  void toggleMetrics() {
    _showMetrics = !_showMetrics;
    notifyListeners();
  }

  void setMetricsVisibility(bool visible) {
    if (_showMetrics == visible) return;
    _showMetrics = visible;
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

  void updateAssistantTextSize(AssistantMessageTextSize size) {
    _assistantTextSize = size;
    notifyListeners();
  }

  @Deprecated('Use updateAssistantTextSize instead.')
  void updateFontSize(double size) {
    final selected = AssistantMessageTextSize.values.firstWhere(
      (candidate) => candidate.fontSize == size,
      orElse: () => AssistantMessageTextSize.medium,
    );
    updateAssistantTextSize(selected);
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

  void closeDebugLab() {
    if (!_debugLabOpen) return;
    _debugLabOpen = false;
    notifyListeners();
  }
}
