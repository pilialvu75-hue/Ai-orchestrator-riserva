import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/tools/code_interpreter_tool.dart';
import 'package:ai_orchestrator/core/tools/tool.dart';

void main() {
  const tool = CodeInterpreterTool();

  group('CodeInterpreterTool – identity', () {
    test('id is code_interpreter', () {
      expect(tool.id, 'code_interpreter');
    });

    test('name is non-empty', () {
      expect(tool.name, isNotEmpty);
    });

    test('description is non-empty', () {
      expect(tool.description, isNotEmpty);
    });
  });

  group('CodeInterpreterTool – safe code', () {
    test('returns success for safe Dart snippet', () async {
      const safeCode = '''
void greet(String name) {
  print('Hello, \$name');
}
''';
      final result = await tool.execute({
        'code': safeCode,
        'language': 'dart',
        'description': 'A greeting function',
      });

      expect(result.success, isTrue);
      expect(result.output, contains('[SAFE]'));
      expect(result.output, contains(safeCode.trim()));
    });

    test('includes language header in output', () async {
      final result = await tool.execute({
        'code': 'print("hello")',
        'language': 'python',
      });
      expect(result.output, contains('Language: python'));
    });

    test('includes description header when provided', () async {
      final result = await tool.execute({
        'code': 'x = 1',
        'language': 'python',
        'description': 'Set x to 1',
      });
      expect(result.output, contains('Set x to 1'));
    });
  });

  group('CodeInterpreterTool – destructive code', () {
    test('flags rm -rf as requiring confirmation', () async {
      final result = await tool.execute({
        'code': 'import subprocess\nsubprocess.run(["rm", "-rf", "/tmp/test"])',
        'language': 'python',
      });
      expect(result.success, isTrue);
      expect(result.output, contains('[REQUIRES CONFIRMATION]'));
    });

    test('flags os.remove as requiring confirmation', () async {
      final result = await tool.execute({
        'code': 'import os\nos.remove("/path/to/file")',
        'language': 'python',
      });
      expect(result.output, contains('[REQUIRES CONFIRMATION]'));
    });

    test('flags File.delete as requiring confirmation', () async {
      final result = await tool.execute({
        'code': 'await File("/data/user").delete()',
        'language': 'dart',
      });
      expect(result.output, contains('[REQUIRES CONFIRMATION]'));
    });

    test('flags Directory.delete as requiring confirmation', () async {
      final result = await tool.execute({
        'code': 'await Directory("/cache").delete(recursive: true)',
        'language': 'dart',
      });
      expect(result.output, contains('[REQUIRES CONFIRMATION]'));
    });

    test('flags shutil.rmtree as requiring confirmation', () async {
      final result = await tool.execute({
        'code': 'import shutil\nshutil.rmtree("/tmp/folder")',
        'language': 'python',
      });
      expect(result.output, contains('[REQUIRES CONFIRMATION]'));
    });

    test('flags DROP TABLE as requiring confirmation', () async {
      final result = await tool.execute({
        'code': 'DROP TABLE users;',
        'language': 'sql',
      });
      expect(result.output, contains('[REQUIRES CONFIRMATION]'));
    });
  });

  group('CodeInterpreterTool – empty input', () {
    test('returns failure for empty code', () async {
      final result = await tool.execute({'code': ''});
      expect(result.success, isFalse);
      expect(result.error, isNotNull);
    });

    test('returns failure when code key is missing', () async {
      final result = await tool.execute({});
      expect(result.success, isFalse);
    });

    test('returns failure for whitespace-only code', () async {
      final result = await tool.execute({'code': '   \n  '});
      expect(result.success, isFalse);
    });
  });

  group('ToolResult', () {
    test('toString contains toolId', () {
      const result = ToolResult(toolId: 'code_interpreter', output: 'ok');
      expect(result.toString(), contains('code_interpreter'));
    });
  });
}
