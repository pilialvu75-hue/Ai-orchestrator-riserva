import 'dart:convert';

import 'package:ai_orchestrator/features/module_library/data/module_research_status_source.dart';
import 'package:http/http.dart' as http;

/// Public, read-only bridge from the shared Diagnostics repository into the
/// Modules dashboard. It never contributes certified availability: it only
/// projects Researcher progress for capabilities that are still missing.
final class GitHubDiagnosticsResearchStatusSource
    implements ModuleResearchStatusSource {
  GitHubDiagnosticsResearchStatusSource({http.Client? client})
      : _client = client ?? http.Client();

  static final Uri _releasesUri = Uri.parse(
    'https://api.github.com/repos/pilialvu75-hue/'
    'Ai-orchestrator-diagnostics/releases?per_page=100',
  );

  final http.Client _client;

  @override
  Future<Map<String, Object?>?> load() async {
    final response = await _client.get(
      _releasesUri,
      headers: const <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'ai-orchestrator-module-dashboard/1',
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) return null;

    final latestByCapability = <String, Map<String, Object?>>{};
    final latestAt = <String, DateTime>{};

    for (final rawRelease in decoded) {
      if (rawRelease is! Map) continue;
      final tag = rawRelease['tag_name']?.toString() ?? '';
      if (!tag.startsWith('diagnostics-researcher-v1-')) continue;
      final body = rawRelease['body']?.toString() ?? '';
      for (final line in body.split('\n')) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) continue;
        Object? event;
        try {
          event = jsonDecode(trimmed);
        } catch (_) {
          continue;
        }
        if (event is! Map) continue;
        if (event['schema'] != 'ai-orchestrator.diagnostics.event.v2' ||
            event['producer'] != 'researcher') {
          continue;
        }
        final fields = event['fields'];
        if (fields is! Map) continue;
        if (fields['component']?.toString() != 'capability_status') continue;
        final capabilityId = fields['capability_id']?.toString().trim() ?? '';
        if (capabilityId.isEmpty) continue;
        final timestamp = DateTime.tryParse(
          event['timestamp']?.toString() ?? '',
        )?.toUtc();
        if (timestamp == null) continue;
        final previous = latestAt[capabilityId];
        if (previous != null && !timestamp.isAfter(previous)) continue;

        latestAt[capabilityId] = timestamp;
        latestByCapability[capabilityId] = <String, Object?>{
          'capability_id': capabilityId,
          'research_state': fields['research_state']?.toString(),
          'candidate_count': _count(fields['candidate_count']),
          'qualified_candidates': _count(fields['qualified_candidates']),
          'shortlisted': _count(fields['shortlisted']),
          'submitted': _count(fields['submitted']),
          'security_review': _count(fields['security_review']),
          'security_blocked': _count(fields['security_blocked']),
          'last_scan': timestamp.toIso8601String(),
        };
      }
    }

    if (latestByCapability.isEmpty) return null;
    final capabilities = latestByCapability.values.toList(growable: false)
      ..sort(
        (left, right) => left['capability_id']
            .toString()
            .compareTo(right['capability_id'].toString()),
      );
    return <String, Object?>{'capabilities': capabilities};
  }

  static int _count(Object? value) {
    if (value is int) return value < 0 ? 0 : value;
    final parsed = int.tryParse(value?.toString() ?? '');
    return parsed == null || parsed < 0 ? 0 : parsed;
  }
}
