import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

/// A canonical, public YouTube video identifier, parsed only from a user's
/// current message. No arbitrary URL or tracking query is ever fetched.
final class AssistantYouTubeLink {
  const AssistantYouTubeLink(this.videoId);

  final String videoId;

  Uri get canonicalUrl =>
      Uri.https('www.youtube.com', '/watch', <String, String>{'v': videoId});

  static AssistantYouTubeLink? fromUserMessage(String message) {
    if (message.length > 4096) return null;
    final candidates = RegExp(r'https?://[^\s<>]+', caseSensitive: false)
        .allMatches(message)
        .toList(growable: false);
    // Avoid silently choosing one URL from a multiple-link request.
    if (candidates.length != 1) return null;
    final raw = candidates.single.group(0)!
        .replaceFirst(RegExp(r'''[)\].,;!?'"]+$'''), '');
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.host.isEmpty ||
        uri.fragment.isNotEmpty) {
      return null;
    }

    final host = uri.host.toLowerCase();
    final segments = uri.pathSegments;
    String? id;
    if (host == 'youtu.be' || host == 'www.youtu.be') {
      if (segments.length == 1) id = segments.single;
    } else if (host == 'youtube.com' ||
        host == 'www.youtube.com' ||
        host == 'm.youtube.com') {
      if (segments.length == 2 &&
          (segments.first == 'shorts' ||
              segments.first == 'embed' ||
              segments.first == 'live')) {
        id = segments.last;
      } else if (segments.length == 1 && segments.single == 'watch') {
        final all = uri.queryParametersAll['v'];
        if (all != null && all.length == 1) id = all.single;
      }
    }
    if (id == null || !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) {
      return null;
    }
    return AssistantYouTubeLink(id);
  }
}

/// YouTube's official oEmbed response can provide title and author only.
/// It does NOT attest to a video's description, captions, audio or images.
final class AssistantYouTubeMetadata {
  const AssistantYouTubeMetadata({
    required this.title,
    required this.channel,
  });

  final String title;
  final String channel;
}

abstract interface class AssistantYouTubeMetadataLookup {
  Future<AssistantYouTubeMetadata?> fetch(AssistantYouTubeLink link);
}

/// Privacy-limited metadata lookup, not a video download or transcript reader.
/// The only external destination is the fixed public youtube.com oEmbed URL,
/// and the only data sent to it is a normalized 11-character video ID.
final class AssistantYouTubeMetadataService
    implements AssistantYouTubeMetadataLookup {
  AssistantYouTubeMetadataService({
    http.Client? client,
    this.timeout = const Duration(seconds: 5),
    this.maxResponseBytes = 16384,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;
  final int maxResponseBytes;

  @override
  Future<AssistantYouTubeMetadata?> fetch(AssistantYouTubeLink link) async {
    final endpoint = Uri.https('www.youtube.com', '/oembed', <String, String>{
      'url': link.canonicalUrl.toString(),
      'format': 'json',
    });
    RuntimeEventLog.instance.emit(
      '[ASSISTANT_YOUTUBE_LINK] stage=metadata_lookup_begin provider=oembed',
    );
    try {
      final request = http.Request('GET', endpoint)
        ..followRedirects = false;
      final response = await _client.send(request).timeout(timeout);
      if (response.statusCode != 200 || response.isRedirect) {
        // Avoid following a redirect to any other host.
        RuntimeEventLog.instance.emit(
          '[ASSISTANT_YOUTUBE_LINK] stage=metadata_lookup_end '
          'status=unavailable http_status=${response.statusCode}',
        );
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(timeout)) {
        if (bytes.length + chunk.length > maxResponseBytes) {
          RuntimeEventLog.instance.emit(
            '[ASSISTANT_YOUTUBE_LINK] stage=metadata_lookup_end '
            'status=unavailable reason=response_too_large',
          );
          return null;
        }
        bytes.addAll(chunk);
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) return null;
      final title = _clean(decoded['title']);
      final author = _clean(decoded['author_name']);
      if (title == null || author == null) {
        RuntimeEventLog.instance.emit(
          '[ASSISTANT_YOUTUBE_LINK] stage=metadata_lookup_end '
          'status=unavailable reason=missing_metadata',
        );
        return null;
      }
      RuntimeEventLog.instance.emit(
        '[ASSISTANT_YOUTUBE_LINK] stage=metadata_lookup_end '
        'status=success title_chars=${title.length} channel_chars=${author.length}',
      );
      return AssistantYouTubeMetadata(title: title, channel: author);
    } catch (error) {
      // Never log request URLs, private prompts or HTTP exception bodies.
      RuntimeEventLog.instance.emit(
        '[ASSISTANT_YOUTUBE_LINK] stage=metadata_lookup_end '
        'status=unavailable error_type=${error.runtimeType}',
      );
      return null;
    }
  }

  static String? _clean(Object? value) {
    if (value is! String) return null;
    final clean = value
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (clean.isEmpty) return null;
    // Bound displayed untrusted metadata (no prompts or tool syntax).
    return clean.length <= 180 ? clean : clean.substring(0, 180);
  }
}
