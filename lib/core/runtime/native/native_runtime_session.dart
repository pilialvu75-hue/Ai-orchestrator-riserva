/// Tracks the state of a single native inference session.
///
/// One [NativeRuntimeSession] corresponds to one call to
/// `llb_start_gen` / `llb_poll_token` / `llb_cancel` on the native side.
/// The session is created via the static [NativeRuntimeSession.create]
/// factory and progresses through: created → active → ended.
class NativeRuntimeSession {
  NativeRuntimeSession._({
    required this.sessionId,
    required this.modelPath,
    required this.startedAt,
  });

  /// Creates a new session for the given [modelPath].
  ///
  /// The [sessionId] is derived from the microsecond timestamp at the moment
  /// of creation, giving a monotonically-increasing unique identifier.
  static NativeRuntimeSession create(String modelPath) {
    return NativeRuntimeSession._(
      sessionId: DateTime.now().microsecondsSinceEpoch.toString(),
      modelPath: modelPath,
      startedAt: DateTime.now(),
    );
  }

  /// Unique identifier for this session.
  final String sessionId;

  /// Absolute path to the model file associated with this session.
  final String modelPath;

  /// Wall-clock time when the session was created.
  final DateTime startedAt;

  bool _isActive = false;
  int _tokenCount = 0;

  /// `true` from the moment [start] is called until [end] is called.
  bool get isActive => _isActive;

  /// Number of tokens produced so far in this session.
  int get tokenCount => _tokenCount;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Marks the session as active.
  ///
  /// Must be called once before polling for tokens.
  void start() {
    _isActive = true;
  }

  /// Marks the session as ended.
  ///
  /// After this call [isActive] returns `false` and no more tokens should be
  /// polled.
  void end() {
    _isActive = false;
  }

  /// Increments the token counter by one.
  ///
  /// Call once per token received from the native bridge.
  void incrementTokenCount() {
    _tokenCount++;
  }

  @override
  String toString() =>
      'NativeRuntimeSession('
      'id=$sessionId, '
      'model=$modelPath, '
      'active=$_isActive, '
      'tokens=$_tokenCount)';
}
