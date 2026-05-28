import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';
import 'package:flutter/foundation.dart';

class DebugLabController extends ChangeNotifier {
  DebugLabController._();

  static final DebugLabController instance = DebugLabController._();

  static const int _requiredRapidTaps = 7;
  static const Duration _maxTapGap = Duration(milliseconds: 500);

  int _rapidTapCount = 0;
  DateTime? _lastTapAt;
  bool _isVisible = false;

  bool get isVisible => _isVisible;

  void registerHeaderTap() {
    final now = DateTime.now();
    final lastTap = _lastTapAt;
    if (lastTap == null || now.difference(lastTap) > _maxTapGap) {
      _rapidTapCount = 1;
    } else {
      _rapidTapCount += 1;
    }
    _lastTapAt = now;
    RuntimeEventLog.instance.emit(
      '[DEBUG_LAB_TAP] count=$_rapidTapCount required=$_requiredRapidTaps',
    );
    if (_rapidTapCount >= _requiredRapidTaps) {
      _rapidTapCount = 0;
      _lastTapAt = null;
      _isVisible = true;
      RuntimeEventLog.instance.emit('[DEBUG_LAB_OVERLAY_OPEN] source=header_taps');
      notifyListeners();
    }
  }

  void close() {
    _rapidTapCount = 0;
    _lastTapAt = null;
    if (!_isVisible) return;
    _isVisible = false;
    RuntimeEventLog.instance.emit('[DEBUG_LAB_OVERLAY_CLOSE] source=panel_close');
    notifyListeners();
  }
}
