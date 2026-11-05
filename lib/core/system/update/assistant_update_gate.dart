/// Coordinates Assistant persistence with a user-requested desktop update.
/// A chat lease covers generation and the final database/embedding writes.
class AssistantUpdateGate {
  static final AssistantUpdateGate instance = AssistantUpdateGate();

  int _activeChats = 0;
  bool _updating = false;
  bool get hasActiveChats => _activeChats > 0;
  bool get isUpdating => _updating;

  void Function() beginChat() {
    if (_updating) {
      throw StateError('An application update is starting. Please retry after restart.');
    }
    _activeChats++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _activeChats--;
    };
  }

  void Function()? tryBeginUpdate() {
    if (_updating || hasActiveChats) return null;
    _updating = true;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _updating = false;
    };
  }
}
