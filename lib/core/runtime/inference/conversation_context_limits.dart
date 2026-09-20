/// Conservative conversation envelope shared by runtimes that need a
/// provider-neutral turn bound before provider-specific token budgeting.
///
/// Android local applies an additional exact GGUF-token budget afterwards.
/// Cloud already used the same 24-turn bound historically; centralizing it
/// prevents conditional recall from being discarded differently after routing.
abstract final class ConversationContextLimits {
  static const int safeCrossRuntimeTurns = 24;
}
