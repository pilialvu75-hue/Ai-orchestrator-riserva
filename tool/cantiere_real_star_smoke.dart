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
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_broker.dart';
import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_request.dart';
import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_inference_provider.dart';
import 'package:ai_orchestrator/core/runtime/inference/token_stream.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart' as crypto;

/// A separate, opt-in real-model star production acceptance lane.
///
/// Unlike cantiere_first_app_smoke.dart, no Engineer source, Architect plan,
/// Reviewer verdict, or expected test implementation is embedded in this file.
/// The existing Cantiere owns planning, review, guarded apply and build. A
/// genuine provider must produce all four roles; errors always fail closed.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('Usage: dart run tool/cantiere_real_star_smoke.dart <flutter-workspace>');
    exitCode = 64;
    return;
  }

  final env = Platform.environment;
  if (env['CANTIERE_ZERO_COST_ROUTES_VERIFIED'] != 'YES') {
    throw StateError('ZERO_COST_PROVIDER_AUTHORIZATION_REQUIRED');
  }
  final base = Uri.tryParse(env['CANTIERE_BROKER_URL'] ?? '');
  if (base == null ||
      base.scheme != 'https' ||
      base.host.isEmpty ||
      base.userInfo.isNotEmpty ||
      base.hasQuery ||
      base.hasFragment ||
      (base.path.isNotEmpty && base.path != '/')) {
    throw StateError('HTTPS_BROKER_ORIGIN_REQUIRED');
  }
  final clientId = env['CANTIERE_CF_ACCESS_CLIENT_ID']?.trim() ?? '';
  final clientSecret = env['CANTIERE_CF_ACCESS_CLIENT_SECRET']?.trim() ?? '';
  if (clientId.isEmpty || clientSecret.isEmpty) {
    throw StateError('CLOUDFLARE_SERVICE_CREDENTIALS_REQUIRED');
  }
  final flutter = env['CANTIERE_FLUTTER_EXECUTABLE']?.trim() ?? '';
  final dart = env['CANTIERE_DART_EXECUTABLE']?.trim() ?? '';
  if (flutter.isEmpty || dart.isEmpty) {
    throw StateError('LOCAL_BUILD_TOOLCHAIN_REQUIRED');
  }

  final workspace = Directory(args.single).absolute;
  if (!await workspace.exists()) {
    throw StateError('WORKSPACE_NOT_FOUND');
  }

  final client = http.Client();
  final roleEvidence = <String, List<String>>{};
  final buildLab = WorkshopBuildLab(providers: <WorkshopBuildProvider>[
    WorkshopLocalBuildProvider(
      configuration: WorkshopLocalBuildConfiguration(
        flutterExecutable: flutter,
        dartExecutable: dart,
        timeout: const Duration(minutes: 25),
      ),
    ),
  ]);
  final gateways = <AppAiRole, WorkshopInferenceGateway>{
    for (final role in <AppAiRole>[
      AppAiRole.workshopOrchestrator,
      AppAiRole.architect,
      AppAiRole.engineer,
      AppAiRole.reviewer,
    ])
      role: WorkshopInferenceGateway(
        provider: _AccessBrokerProvider(
          client: client,
          origin: base,
          accessClientId: clientId,
          accessClientSecret: clientSecret,
          capability: WorkshopWebCloudRolePolicy.capabilityForRole(role).id,
          roleEvidence: roleEvidence,
        ),
      ),
  };

  final bundle = WorkshopProductionLifecycleBundleFactory.create(
    projectExecutor: WorkshopFactory.createProjectExecutor(
      workspaceRootPath: workspace.path,
    ),
    roleGateways: gateways,
    buildLab: buildLab,
    workspaceRootPath: workspace.path,
  );
  final coordinator = WorkshopProductionTaskCoordinator(bundle: bundle);

  try {
    final initial = await coordinator.startAndPrepare(
      title: 'Prima Stella — acceptance reale',
      instruction: 'Crea una vera app Flutter Android con sfondo nero e '
          'una grande stella centrata. Toccando la stella il colore deve '
          'cambiare visibilmente. Fornisci codice e test eseguibili. '
          'Non usare dipendenze extra. Mantieni un solo punto di ingresso.',
      technologies: const <String>['Flutter', 'Dart'],
      deliverables: const <String>['APK Android installabile'],
      validationCriteria: const <String>[
        'Schermata iniziale con sfondo nero.',
        'Stella realmente visibile al centro.',
        'Toccando la stella il suo colore cambia.',
        'Punto di ingresso Flutter valido e import risolti.',
        'Test widget verificano la funzione di cambio colore.',
        'Analyzer, test e build APK reali terminano con successo.',
      ],
    );

    var handle = initial;
    var attempted = 0;
    while (true) {
      attempted++;
      if (attempted > 8) throw StateError('BOUNDED_TASK_LIMIT_EXCEEDED');
      stdout.writeln('[REAL_STAR] stage=inference task=$attempted');
      final inference = await coordinator.runPrepared(
        handle: handle,
        isOffline: false,
      );
      if (!inference.readyForApproval) {
        throw StateError('REAL_MODEL_PROPOSAL_REJECTED');
      }
      // Only a fully validated proposal reaches this guarded approval.
      // This explicit experiment is restricted to its disposable workspace.
      coordinator.decide(
        handle: handle,
        decision: WorkshopApplyDecision.approve,
      );
      await coordinator.applyApproved(handle: handle);
      if (handle.plan.isComplete) break;
      final next = await bundle.dashboardController.prepareNextTask();
      if (next == null) throw StateError('NEXT_TASK_MISSING');
      handle = coordinator.preparedHandle();
    }

    if (initial.plan.completedTasks != initial.plan.totalTasks) {
      throw StateError('PROJECT_INCOMPLETE');
    }

    final result = await coordinator.buildWorkspace(
      target: WorkshopBuildTarget.android,
      mode: WorkshopBuildExecutionMode.offlineLocal,
      runFormatter: true,
      runAnalyzer: true,
      runTests: true,
    );
    if (!result.succeeded || !result.hasArtifact) {
      throw StateError('REAL_STAR_BUILD_GATE_FAILED');
    }
    final apk = File(result.artifactPath!);
    if (!await apk.exists() || await apk.length() == 0) {
      throw StateError('REAL_STAR_APK_MISSING');
    }
    const requiredCapabilities = <String>[
      'orchestration', 'architecture_reasoning', 'coding', 'review',
    ];
    if (requiredCapabilities.any((capability) =>
        roleEvidence[capability] == null ||
        roleEvidence[capability]!.isEmpty)) {
      throw StateError('REAL_STAR_FOUR_ROLE_EVIDENCE_INCOMPLETE');
    }
    final evidence = <String, Object?>{
      'gate': 'REAL_STAR_PRODUCTION_BUILD',
      'production_lifecycle': 'existing_cantiere',
      'inference': 'cloudflare_protected_broker',
      'four_roles_replied': true,
      'broker_model_ids_observed': true,
      'independent_model_generation_provenance_verified': false,
      'artifact_built': true,
      'apk_sha256': crypto.sha256.convert(await apk.readAsBytes()).toString(),
      'emulator_visual_verified': false,
      'geometric_star_verified': false,
      'android_local_verified': false,
      'windows_local_verified': false,
      'role_receipts': <String, Object?>{
        for (final capability in requiredCapabilities)
          capability: <String, Object?>{
            'successful_calls': roleEvidence[capability]!.length,
            'models': roleEvidence[capability]!.toSet().toList()..sort(),
          },
      },
    };
    await File('${workspace.path}/cantiere-real-star-provenance.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
    stdout.writeln('[REAL_STAR] stage=artifact status=ready bytes=${await apk.length()}');
    stdout.writeln('CANTIERE_REAL_STAR_APK=${apk.path}');
    stdout.writeln('REAL_STAR_MODEL_PRODUCTION_BUILD_PASS');
    stdout.writeln('EMULATOR_TAP_COLOR_AND_LOCAL_DEVICE_VERIFICATION_PENDING');
  } finally {
    bundle.dashboardController.dispose();
    await buildLab.dispose();
    client.close();
  }
}

final class _AccessBrokerProvider implements RuntimeInferenceProvider {
  _AccessBrokerProvider({
    required this.client,
    required this.origin,
    required this.accessClientId,
    required this.accessClientSecret,
    required this.capability,
    required this.roleEvidence,
  });

  final http.Client client;
  final Uri origin;
  final String accessClientId;
  final String accessClientSecret;
  final String capability;
  final Map<String, List<String>> roleEvidence;

  @override
  TokenStream streamInference({
    required InferenceRequest request,
    required CancellationToken cancellationToken,
  }) async* {
    if (request.isOffline || cancellationToken.isCancelled) {
      yield InferenceResponse.error(
        'REAL_STAR_PROVIDER_NOT_ALLOWED',
        providerId: 'web_auto',
      );
      return;
    }
    final messages = <Map<String, String>>[];
    if (request.systemPrompt?.trim().isNotEmpty == true) {
      messages.add(<String, String>{
        'role': 'system',
        'content': request.systemPrompt!.trim(),
      });
    }
    for (final item in request.context) {
      if (item.excludeFromContext || item.content.trim().isEmpty) continue;
      final role = item.role.toString().split('.').last;
      messages.add(<String, String>{
        'role': role,
        'content': item.content.trim(),
      });
    }
    messages.add(<String, String>{'role': 'user', 'content': request.prompt.trim()});

    try {
      final uri = origin.resolve('/api/cantiere/inference');
      // Reject redirect responses rather than forwarding Access credentials.
      final requestHttp = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll(<String, String>{
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'X-Requested-With': 'XMLHttpRequest',
          'CF-Access-Client-Id': accessClientId,
          'CF-Access-Client-Secret': accessClientSecret,
        })
        ..body = jsonEncode(<String, Object?>{
          'version': 1,
          'capability': capability,
          'messages': messages,
          'maxTokens': request.maxTokens,
          'temperature': request.temperature,
          'topP': request.topP,
          if (request.requestId != null) 'requestId': request.requestId,
          if (request.projectId != null) 'projectId': request.projectId,
          if (request.taskId != null) 'taskId': request.taskId,
          if (request.executionId != null) 'executionId': request.executionId,
          if (request.attemptId != null) 'attemptId': request.attemptId,
          if (request.checkpointId != null) 'checkpointId': request.checkpointId,
        });
      final stream = await client.send(requestHttp)
          .timeout(const Duration(seconds: 95));
      if (stream.statusCode != 200) {
        yield InferenceResponse.error(
          'REAL_STAR_BROKER_HTTP_${stream.statusCode}',
          providerId: 'web_auto',
        );
        return;
      }
      final response = await http.Response.fromStream(stream);
      if (!(response.headers['content-type'] ?? '').contains('json') ||
          response.bodyBytes.length > 1024 * 1024) {
        yield InferenceResponse.error('REAL_STAR_INVALID_BROKER_PAYLOAD', providerId: 'web_auto');
        return;
      }
      final json = jsonDecode(response.body);
      if (json is! Map || json['text'] is! String ||
          (json['text'] as String).trim().isEmpty ||
          json['model'] is! String ||
          (json['model'] as String).trim().isEmpty) {
        yield InferenceResponse.error('REAL_STAR_MISSING_MODEL_PROVENANCE', providerId: 'web_auto');
        return;
      }
      if (cancellationToken.isCancelled) {
        yield InferenceResponse.error('REAL_STAR_CANCELLED', providerId: 'web_auto');
        return;
      }
      roleEvidence.putIfAbsent(capability, () => <String>[])
          .add((json['model'] as String).trim());
      yield InferenceResponse.finalChunk(
        text: (json['text'] as String).trim(),
        model: (json['model'] as String).trim(),
        providerId: 'web_auto',
        tokensGenerated: json['tokensGenerated'] is num
            ? (json['tokensGenerated'] as num).toInt()
            : 0,
      );
    } on Object {
      yield InferenceResponse.error(
        'REAL_STAR_BROKER_UNREACHABLE_OR_INVALID',
        providerId: 'web_auto',
      );
    }
  }
}
