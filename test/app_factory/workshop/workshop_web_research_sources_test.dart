import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_research_service.dart';
import 'package:ai_orchestrator/core/tools/tool.dart';

void main() {
  const request = WorkshopRequest(
    id: 'structured-web-research',
    title: 'Nuova applicazione',
    instruction: 'Crea una nuova applicazione completa.',
    operation: WorkshopOperation.create,
  );

  test('preserves typed Web sources per research lane', () async {
    final tool = _SequenceSearchTool(<ToolResult>[
      _success('https://example.com/competitor', 'Competitor'),
      _success('https://example.com/forum', 'Forum'),
      _success('https://example.com/domain', 'Domain'),
    ]);
    final service = WorkshopWebResearchService(webSearchTool: tool);

    final result = await service.research(request: request);

    expect(tool.calls, 3);
    expect(result.evidence, hasLength(3));
    expect(result.sourceCount, 3);
    expect(
      result.evidence.map((entry) => entry.sources.single.url),
      <String>[
        'https://example.com/competitor',
        'https://example.com/forum',
        'https://example.com/domain',
      ],
    );
    expect(result.evidence.first.sources.single.title, 'Competitor');
    expect(
      result.evidence.first.sources.single.snippet,
      'Structured source evidence.',
    );
  });

  for (final failureReason in <String>['timeout', 'failure']) {
    test('opens the research circuit after $failureReason', () async {
      final tool = _SequenceSearchTool(<ToolResult>[
        ToolResult(
          toolId: 'web_search',
          output: '',
          success: false,
          error: 'unavailable',
          metadata: <String, Object?>{'failure_reason': failureReason},
        ),
        _success('https://example.com/should-not-run', 'Unused'),
      ]);
      final service = WorkshopWebResearchService(webSearchTool: tool);

      final result = await service.research(request: request);

      expect(tool.calls, 1);
      expect(result.attempted, isTrue);
      expect(result.evidence, hasLength(1));
      expect(result.evidence.single.failureReason, failureReason);
      expect(result.sourceCount, 0);
    });
  }

  test('no_results does not open the circuit for the remaining lanes', () async {
    final tool = _SequenceSearchTool(<ToolResult>[
      const ToolResult(
        toolId: 'web_search',
        output: '',
        success: false,
        error: 'No search results found.',
        metadata: <String, Object?>{'failure_reason': 'no_results'},
      ),
      _success('https://example.com/forum', 'Forum'),
      _success('https://example.com/domain', 'Domain'),
    ]);
    final service = WorkshopWebResearchService(webSearchTool: tool);

    final result = await service.research(request: request);

    expect(tool.calls, 3);
    expect(result.evidence, hasLength(3));
    expect(result.evidence.first.failureReason, 'no_results');
    expect(result.evidence.first.sources, isEmpty);
    expect(result.sourceCount, 2);
    expect(result.successfulLaneCount, 2);
  });

  test('malformed source metadata is ignored instead of reparsed from text',
      () async {
    final tool = _SequenceSearchTool(<ToolResult>[
      const ToolResult(
        toolId: 'web_search',
        output:
            '1. Presentation-only URL\n   URL: https://example.com/text-only',
        metadata: <String, Object?>{
          'results': <Object?>[
            <String, Object?>{'title': 'Missing URL'},
            'not-a-map',
          ],
        },
      ),
      _success('https://example.com/forum', 'Forum'),
      _success('https://example.com/domain', 'Domain'),
    ]);
    final service = WorkshopWebResearchService(webSearchTool: tool);

    final result = await service.research(request: request);

    expect(tool.calls, 3);
    expect(result.evidence.first.hasEvidence, isTrue);
    expect(result.evidence.first.sources, isEmpty);
    expect(result.sourceCount, 2);
  });
}

ToolResult _success(String url, String title) => ToolResult(
      toolId: 'web_search',
      output: '1. $title\n   URL: $url\n   Snippet: Structured source evidence.',
      metadata: <String, Object?>{
        'results': <Object?>[
          <String, Object?>{
            'title': title,
            'url': url,
            'snippet': 'Structured source evidence.',
          },
        ],
      },
    );

final class _SequenceSearchTool implements Tool {
  _SequenceSearchTool(this.responses);

  final List<ToolResult> responses;
  int calls = 0;

  @override
  String get id => 'web_search';

  @override
  String get name => 'Sequence Web Search';

  @override
  String get description => 'Returns deterministic structured Web responses.';

  @override
  Future<ToolResult> execute(Map<String, dynamic> params) async {
    final index = calls;
    calls += 1;
    if (index >= responses.length) {
      throw StateError('Unexpected search call $calls');
    }
    return responses[index];
  }
}
