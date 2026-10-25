/// Host-owned source-evidence sizing. Defaults preserve the established
/// constrained-device path. Larger hosts can retain more source in review and
/// validation without changing verdict, approval, scope or application gates.
final class WorkshopSourcePromptPolicy {
  const WorkshopSourcePromptPolicy({
    this.maxPromptChars = 7000,
    this.primaryFileChars = 2400,
    this.retryFileChars = 1200,
    this.implementationWorkspaceChars = 1800,
    this.implementationRetryWorkspaceChars = 900,
    this.implementationMaxTokens = 640,
    this.implementationRetryMaxTokens = 512,
    this.implementationMalformedRetryMaxTokens = 768,
  })  : assert(maxPromptChars > 0),
        assert(primaryFileChars > 0),
        assert(retryFileChars > 0),
        assert(implementationWorkspaceChars > 0),
        assert(implementationRetryWorkspaceChars > 0),
        assert(implementationMaxTokens > 0),
        assert(implementationRetryMaxTokens > 0),
        assert(implementationMalformedRetryMaxTokens > 0);

  final int maxPromptChars;
  final int primaryFileChars;
  final int retryFileChars;
  final int implementationWorkspaceChars;
  final int implementationRetryWorkspaceChars;
  final int implementationMaxTokens;
  final int implementationRetryMaxTokens;
  final int implementationMalformedRetryMaxTokens;
}
