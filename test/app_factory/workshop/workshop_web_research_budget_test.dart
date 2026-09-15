import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_contract.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_web_research_service.dart';
import 'package:ai_orchestrator/core/tools/tool.dart';

void main() {
  test('default Web research keeps the complete evidence pack bounded', () async {
    final tool = _LargeSearchTool();
    final service = WorkshopWebResearchService(webSearchTool: tool);

    final result = await service.research(
      request: const WorkshopRequest(
        id: 'bounded-recipe-research',
        title: 'App di ricette',
        instruction: 'Crea una nuova app di ricette per famiglie.',
        operation: WorkshopOperation.create,
      ),
    );

    expect(result.attempted, isTrue);
    expect(tool.calls, 3);
    expect(result.evidence, hasLength(3));

    final totalEvidenceChars = result.evidence.fold<int>(
      0,
      (total, entry) => total + entry.output.length,
    );

    expect(totalEvidenceChars, lessThanOrEqualTo(6000));
    for (final entry in result.evidence) {
      expect(entry.output.length, lessThanOrEqualTo(2400));
    }

    // With the default 6k aggregate budget all three research lanes still
    // retain useful evidence instead of allowing the first lane to monopolize
    // the local model context.
    expect(result.successfulLaneCount, 3);
  });
}

final class _LargeSearchTool implements Tool {
  int calls = 0;

  @override
  String get id => 'web_search';

  @override
  String get name => 'Large Web Search';

  @override
  String get description => 'Returns intentionally oversized test evidence.';

  @override
  Future<ToolResult> execute(Map<String, dynamic> params) async {
    calls += 1;
    final body = List<String>.filled(10000, String.fromCharCode(96 + calls)).join();
    return ToolResult(toolId: id, output: body);
  }
}
