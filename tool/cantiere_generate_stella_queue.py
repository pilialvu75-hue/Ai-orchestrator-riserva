#!/usr/bin/env python3
"""Generate a minimal Flutter application that consumes the Library async adapter.

The adapter must be independently rebuilt and tested before running this generator.
This is an experimental Cantiere output, not an admitted production module.
"""
import argparse
from pathlib import Path

PUBSPEC = """name: aivexus_stella_queue
description: First experimental Cantiere app using a rebuilt Library adapter.
publish_to: none
version: 0.1.0+1
environment:
  sdk: '>=3.4.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  aivexus_external_async:
    path: modules/aivexus_external_async
dev_dependencies:
  flutter_test:
    sdk: flutter
dependency_overrides:
  async:
    path: modules/aivexus_external_async/vendor/async
flutter:
  uses-material-design: true
"""

MAIN = """import 'dart:async';
import 'package:flutter/material.dart';
import 'package:aivexus_external_async/aivexus_external.dart';

void main() => runApp(const StellaQueueApp());

class StellaQueueApp extends StatelessWidget {
  const StellaQueueApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Stella Queue',
    home: const StellaQueuePage(),
  );
}

class StellaQueuePage extends StatefulWidget {
  const StellaQueuePage({super.key});

  @override
  State<StellaQueuePage> createState() => _StellaQueuePageState();
}

class _StellaQueuePageState extends State<StellaQueuePage> {
  String result = 'Pronto';
  bool running = false;

  Future<void> runQueue() async {
    if (running) return;
    setState(() {
      running = true;
      result = 'Elaborazione';
    });
    final queue = StreamQueue<int>(Stream<int>.fromIterable([1, 2, 3]));
    try {
      final values = <int>[];
      while (await queue.hasNext) {
        values.add(await queue.next);
      }
      if (mounted) setState(() => result = values.join(', '));
    } catch (error) {
      if (mounted) setState(() => result = 'Errore: $error');
    } finally {
      await queue.cancel();
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Stella Queue')),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(result, key: const Key('queue-result')),
          ElevatedButton(
            onPressed: running ? null : runQueue,
            child: const Text('Esegui modulo'),
          ),
        ],
      ),
    ),
  );
}
"""

TEST = """import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aivexus_stella_queue/main.dart';

void main() {
  testWidgets('runs real Library StreamQueue adapter', (tester) async {
    await tester.pumpWidget(const StellaQueueApp());
    expect(find.text('Pronto'), findsOneWidget);
    await tester.tap(find.text('Esegui modulo'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('queue-result')), findsOneWidget);
    expect(find.text('1, 2, 3'), findsOneWidget);
  });
}
"""

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--values', default='1,2,3', help='Comma-separated integers for the generated queue')
    args = parser.parse_args()
    try:
        values = [int(value.strip()) for value in args.values.split(',')]
    except ValueError:
        parser.error('--values must contain comma-separated integers')
    if not values or len(values) > 100:
        parser.error('--values requires between 1 and 100 integers')
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('Output directory must be empty: ' + str(output))
    expected = ', '.join(str(value) for value in values)
    generated_main = MAIN.replace('Stream<int>.fromIterable([1, 2, 3])', 'Stream<int>.fromIterable(' + repr(values) + ')')
    generated_test = TEST.replace("expect(find.text('1, 2, 3'), findsOneWidget);", "expect(find.text('" + expected + "'), findsOneWidget);")
    for name, data in {
        'pubspec.yaml': PUBSPEC,
        'lib/main.dart': generated_main,
        'test/widget_test.dart': generated_test,
    }.items():
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data, encoding='utf-8')
    print('GENERATED_FLUTTER_APP_NOT_YET_TESTED=' + str(output))

if __name__ == '__main__':
    main()
