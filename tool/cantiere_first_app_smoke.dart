import 'dart:convert';
import 'dart:io';

import 'package:ai_orchestrator/app_factory/models/workshop_model_roles.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_apply_approval_gate.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_build_lab.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_factory.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_local_build_provider.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_lifecycle_bundle.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_production_task_handle.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';

/// End-to-end acceptance smoke for the first real Cantiere product.
///
/// The Flutter scaffold is prepared by CI before this program starts. From that
/// point onward this smoke uses the production Cantiere boundaries:
/// Project/Task -> WorkspaceSession -> Orchestrator -> Architect -> Engineer ->
/// Reviewer -> validation -> explicit approval -> guarded apply -> Build Lab ->
/// real APK.
///
/// When [--prepare-only] is supplied, the guarded Cantiere lifecycle stops just
/// after apply/format. This mode exists for Flutter-test based CI: the outer
/// `flutter test` process owns the Flutter SDK lock, so the real analyzer/tests/
/// APK build are executed by the workflow immediately after that process exits.
/// The generated workspace is the same workspace produced by this lifecycle.
///
/// Inference is deterministic on purpose: this test validates orchestration,
/// workspace safety and the real build path without making CI depend on a model,
/// provider quota or network. Real-model device validation remains a separate
/// acceptance gate.
Future<void> main(List<String> args) async {
  final prepareOnly = args.length == 2 && args[1] == '--prepare-only';
  if (args.isEmpty || args.length > 2 || (args.length == 2 && !prepareOnly)) {
    stderr.writeln(
      'Usage: dart run tool/cantiere_first_app_smoke.dart '
      '<workspace-path> [--prepare-only]',
    );
    exitCode = 64;
    return;
  }

  final workspace = Directory(args.first).absolute;
  if (!await workspace.exists()) {
    stderr.writeln('Workspace does not exist: ${workspace.path}');
    exitCode = 66;
    return;
  }

  final flutterExecutable =
      Platform.environment['CANTIERE_FLUTTER_EXECUTABLE']?.trim();
  final dartExecutable =
      Platform.environment['CANTIERE_DART_EXECUTABLE']?.trim();

  if (flutterExecutable == null || flutterExecutable.isEmpty) {
    stderr.writeln('CANTIERE_FLUTTER_EXECUTABLE is required.');
    exitCode = 78;
    return;
  }
  if (dartExecutable == null || dartExecutable.isEmpty) {
    stderr.writeln('CANTIERE_DART_EXECUTABLE is required.');
    exitCode = 78;
    return;
  }

  final executor = WorkshopFactory.createProjectExecutor(
    workspaceRootPath: workspace.path,
  );
  final buildLab = WorkshopBuildLab(
    providers: <WorkshopBuildProvider>[
      WorkshopLocalBuildProvider(
        configuration: WorkshopLocalBuildConfiguration(
          flutterExecutable: flutterExecutable,
          dartExecutable: dartExecutable,
          timeout: const Duration(minutes: 20),
        ),
      ),
    ],
  );

  final gateways = <AppAiRole, WorkshopInferenceGateway>{
    AppAiRole.workshopOrchestrator: WorkshopInferenceGateway(
      provider: _ScriptedRuntimeProvider(_orchestratorResponse),
    ),
    AppAiRole.architect: WorkshopInferenceGateway(
      provider: _ScriptedRuntimeProvider(_architectResponse),
    ),
    AppAiRole.engineer: WorkshopInferenceGateway(
      provider: _ScriptedRuntimeProvider(_engineerResponse),
    ),
    AppAiRole.reviewer: WorkshopInferenceGateway(
      provider: _ScriptedRuntimeProvider(_reviewerResponse),
    ),
  };

  final bundle = WorkshopProductionLifecycleBundleFactory.create(
    projectExecutor: executor,
    roleGateways: gateways,
    buildLab: buildLab,
    workspaceRootPath: workspace.path,
  );
  final coordinator = WorkshopProductionTaskCoordinator(bundle: bundle);

  try {
    stdout.writeln('[FIRST_APP] stage=project status=starting');
    final handle = await coordinator.startAndPrepare(
      title: 'Prima app Cantiere - Contatore',
      instruction:
          'Crea una semplice app Flutter contatore con pulsante +, pulsante - '
          'e pulsante Reset. Deve funzionare su Android.',
      technologies: const <String>['Flutter', 'Dart'],
      deliverables: const <String>['APK Android installabile'],
      validationCriteria: const <String>[
        'Il contatore parte da zero.',
        'Il pulsante + incrementa di uno.',
        'Il pulsante - decrementa di uno.',
        'Il pulsante Reset riporta il valore a zero.',
        'flutter analyze e flutter test terminano senza errori.',
        'La build produce un APK Android reale.',
      ],
    );

    stdout.writeln(
      '[FIRST_APP] stage=inference status=running task=${handle.taskId}',
    );
    final inference = await coordinator.runPrepared(
      handle: handle,
      isOffline: true,
    );
    if (!inference.readyForApproval) {
      throw StateError('Cantiere proposal did not reach approval-ready state.');
    }

    stdout.writeln('[FIRST_APP] stage=approval status=approved');
    coordinator.decide(
      handle: handle,
      decision: WorkshopApplyDecision.approve,
    );
    await coordinator.applyApproved(handle: handle);

    stdout.writeln('[FIRST_APP] stage=format status=checking');
    final format = await Process.run(
      dartExecutable,
      const <String>[
        'format',
        '--output=none',
        '--set-exit-if-changed',
        'lib',
        'test',
      ],
      workingDirectory: workspace.path,
      runInShell: false,
    );
    if (format.exitCode != 0) {
      throw StateError(
        'dart format check failed (${format.exitCode}).\n'
        '${format.stdout}\n${format.stderr}',
      );
    }

    if (prepareOnly) {
      stdout.writeln(
        '[FIRST_APP] stage=workspace status=ready path=${workspace.path}',
      );
      return;
    }

    stdout.writeln('[FIRST_APP] stage=build status=running target=android');
    final build = await coordinator.buildWorkspace(
      target: WorkshopBuildTarget.android,
      mode: WorkshopBuildExecutionMode.offlineLocal,
      runFormatter: false,
      runAnalyzer: true,
      runTests: true,
    );

    if (!build.succeeded || !build.hasArtifact) {
      throw StateError(
        'Cantiere first-app build failed: ${build.message}\n'
        'errors=${build.errors}\n${build.stderr}',
      );
    }

    final artifact = File(build.artifactPath!);
    if (!await artifact.exists()) {
      throw StateError(
        'Build Lab reported an artifact that does not exist: ${artifact.path}',
      );
    }

    final bytes = await artifact.length();
    if (bytes <= 0) {
      throw StateError('Generated APK is empty: ${artifact.path}');
    }

    stdout.writeln('[FIRST_APP] stage=artifact status=ready bytes=$bytes');
    stdout.writeln('CANTIERE_FIRST_APP_APK=${artifact.path}');
  } finally {
    bundle.dashboardController.dispose();
    await buildLab.dispose();
  }
}

final class _ScriptedRuntimeProvider extends RuntimeInferenceProvider {
  _ScriptedRuntimeProvider(this._responseFor);

  final String Function(InferenceRequest request) _responseFor;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    final response = _responseFor(request);
    yield InferenceResponse.finalChunk(
      text: response,
      tokensGenerated: 1,
      model: 'cantiere-first-app-ci-fixture',
      providerId: 'deterministic-ci',
    );
  }
}

String _orchestratorResponse(InferenceRequest request) =>
    'Richiesta fattibile con lo scaffold Flutter esistente. '
    'Non servono dipendenze esterne. Verificare incremento, decremento, reset, '
    'analyzer, widget test e produzione APK Android.';

String _architectResponse(InferenceRequest request) =>
    'Mantieni lo scaffold Android generato da Flutter. Sostituisci lib/main.dart '
    'con una UI Material minimale a stato locale e aggiorna test/widget_test.dart '
    'con un test dei tre comandi. Non aggiungere dipendenze.';

String _engineerResponse(InferenceRequest request) {
  return jsonEncode(<String, Object?>{
    'summary': 'Implementa la prima app contatore del Cantiere.',
    'explanation':
        'Usa solo Flutter SDK, stato locale e un widget test deterministico.',
    'analysis': 'Lo scaffold Android esistente è sufficiente.',
    'changes': <Map<String, Object?>>[
      <String, Object?>{
        'path': 'lib/main.dart',
        'type': 'modification',
        'content': _counterMainDart,
      },
      <String, Object?>{
        'path': 'test/widget_test.dart',
        'type': 'modification',
        'content': _counterWidgetTest,
      },
    ],
    'validationNotes': <String>[
      'Verificare +, -, Reset con flutter test.',
      'Eseguire flutter analyze prima della build.',
    ],
    'warnings': const <String>[],
  });
}

String _reviewerResponse(InferenceRequest request) {
  if (request.sessionId.contains(':validation:')) {
    return jsonEncode(<String, Object?>{
      'valid': true,
      'summary': 'Modifiche coerenti e pronte per il gate di apply.',
      'checks': <String>[
        'Stato contatore iniziale a zero.',
        'Azioni incremento, decremento e reset presenti.',
        'Widget test presente.',
      ],
      'warnings': const <String>[],
    });
  }

  return jsonEncode(<String, Object?>{
    'approved': true,
    'summary': 'Implementazione minima coerente con la richiesta.',
    'findings': const <String>[],
    'warnings': const <String>[],
  });
}

const String _counterMainDart = r'''
import 'package:flutter/material.dart';

void main() {
  runApp(const CounterApp());
}

class CounterApp extends StatelessWidget {
  const CounterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Contatore',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const CounterPage(),
    );
  }
}

class CounterPage extends StatefulWidget {
  const CounterPage({super.key});

  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> {
  int _count = 0;

  void _increment() => setState(() => _count++);
  void _decrement() => setState(() => _count--);
  void _reset() => setState(() => _count = 0);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Contatore')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('Valore corrente'),
            const SizedBox(height: 12),
            Text(
              '$_count',
              key: const Key('counter-value'),
              style: Theme.of(context).textTheme.displayMedium,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: <Widget>[
                FilledButton(
                  key: const Key('decrement-button'),
                  onPressed: _decrement,
                  child: const Text('-'),
                ),
                FilledButton(
                  key: const Key('increment-button'),
                  onPressed: _increment,
                  child: const Text('+'),
                ),
                OutlinedButton(
                  key: const Key('reset-button'),
                  onPressed: _reset,
                  child: const Text('Reset'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
''';

const String _counterWidgetTest = r'''
import 'package:cantiere_first_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('incrementa, decrementa e resetta il contatore', (tester) async {
    await tester.pumpWidget(const CounterApp());

    expect(find.byKey(const Key('counter-value')), findsOneWidget);
    expect(find.text('0'), findsOneWidget);

    await tester.tap(find.byKey(const Key('increment-button')));
    await tester.pump();
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('decrement-button')));
    await tester.pump();
    expect(find.text('0'), findsOneWidget);

    await tester.tap(find.byKey(const Key('increment-button')));
    await tester.tap(find.byKey(const Key('increment-button')));
    await tester.pump();
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('reset-button')));
    await tester.pump();
    expect(find.text('0'), findsOneWidget);
  });
}
''';
