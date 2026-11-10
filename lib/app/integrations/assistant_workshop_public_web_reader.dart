import 'package:ai_orchestrator/app_factory/workshop/workshop_safe_web_page_fetch_stack.dart';
import 'package:ai_orchestrator/core/tools/search/assistant_public_web_link.dart';

/// Adapter that REUSES Cantiere's DNS-pinned public Web reader.
///
/// It does not send the user's message, chat history, personal memory or model
/// prompts to the destination: only the explicitly supplied URL is requested.
/// The page is untrusted and is returned solely as a short, labeled excerpt.
final class AssistantWorkshopPublicWebReader implements AssistantPublicWebReader {
  const AssistantWorkshopPublicWebReader();

  @override
  Future<AssistantPublicWebExcerpt?> read(AssistantPublicWebLink link) async {
    final stack = WorkshopSafeWebPageFetchStack.create(
      timeout: const Duration(seconds: 6),
      maxBytes: 96 * 1024,
      maxTextChars: 1800,
      maxRedirects: 2,
    );

    try {
      final response = await stack.fetcher.fetch(link.url.toString());
      if (!response.isSuccess || response.page == null) return null;
      final page = response.page!;
      final text = page.text.trim();
      if (text.isEmpty) return null;
      return AssistantPublicWebExcerpt(
        host: page.url.host,
        text: text,
      );
    } catch (_) {
      // Fetcher logs only coarse statuses, not full query URLs or page text.
      return null;
    } finally {
      stack.close();
    }
  }
}
