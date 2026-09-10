// Compatibility export for callers that still use the historical chat-memory
// path. The canonical conversation contract belongs to core because runtime,
// Cloud and Workshop inference boundaries consume it directly.
export 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';
