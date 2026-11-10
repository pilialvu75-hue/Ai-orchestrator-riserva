/// A single HTTPS page link supplied in the CURRENT user message.
///
/// This class does not open network connections: callers must still use a
/// public-address-validated, DNS-pinned HTTP transport. It never interprets
/// links that appear only in documents, assistant replies or older context.
final class AssistantPublicWebLink {
  const AssistantPublicWebLink._(this.url);

  final Uri url;

  static AssistantPublicWebLink? fromUserMessage(String input) {
    if (input.isEmpty || input.length > 4096) return null;
    final links = RegExp(r'https?://[^\s<>]+', caseSensitive: false)
        .allMatches(input)
        .toList(growable: false);
    if (links.length != 1) return null;
    final raw = links.single.group(0)!
        .replaceFirst(RegExp(r'''[)\].,;!?'"]+$'''), '');
    final parsed = Uri.tryParse(raw);
    if (parsed == null ||
        parsed.scheme.toLowerCase() != 'https' ||
        !parsed.hasAuthority ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasPort) {
      return null;
    }

    final host = parsed.host.toLowerCase();
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.home.arpa') ||
        host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        host == 'youtu.be' ||
        host.endsWith('.youtu.be') ||
        host == 'youtube-nocookie.com' ||
        host.endsWith('.youtube-nocookie.com')) {
      // YouTube has a separate source-specific metadata path; never read a
      // YouTube watch page and mistake its boilerplate for video content.
      return null;
    }

    // Fragments identify sections on a client page, not HTTP resources.
    final normalized = Uri.parse(parsed.toString().split('#').first);
    return AssistantPublicWebLink._(normalized);
  }
}

/// Verified source extraction, not a generated summary.
final class AssistantPublicWebExcerpt {
  const AssistantPublicWebExcerpt({
    required this.host,
    required this.text,
  });

  final String host;
  final String text;
}

/// The implementation lives in the application layer, where the hardened
/// public Web fetch stack can be shared with Cantiere. LOCAL receives only
/// the extracted public text, never an outbound Cloud inference request.
abstract interface class AssistantPublicWebReader {
  Future<AssistantPublicWebExcerpt?> read(AssistantPublicWebLink link);
}
