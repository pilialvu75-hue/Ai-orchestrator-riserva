import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A synthetic end-to-end probe, separate from Workshop projects and chats.
/// The broker restricts it to server-authorized, zero-cost routes only.
final class WorkshopWebCloudSelfTestResult {
  const WorkshopWebCloudSelfTestResult({
    required this.passed,
    required this.detail,
    required this.elapsed,
    this.statusCode,
    this.errorCode,
    this.provider,
    this.configuredModel,
    this.reportedModel,
    this.routeId,
    this.tokensGenerated,
  });

  final bool passed;
  final String detail;
  final Duration elapsed;
  final int? statusCode;
  final String? errorCode;
  final String? provider;
  final String? configuredModel;
  final String? reportedModel;
  final String? routeId;
  final int? tokensGenerated;
}

final class WorkshopWebCloudSelfTestClient {
  WorkshopWebCloudSelfTestClient({
    http.Client? client,
    Uri? baseUri,
    this.timeout = const Duration(seconds: 90),
  })  : _client = client ?? http.Client(),
        _baseUri = baseUri ?? Uri.base;

  static const String expectedMarker = 'AIVEXUS_WEB_SELF_TEST_OK';

  final http.Client _client;
  final Uri _baseUri;
  final Duration timeout;

  Uri get endpoint => _baseUri.resolve('/api/cantiere/inference');

  Future<WorkshopWebCloudSelfTestResult> run({String? routeId}) async {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _client
          .post(
            endpoint,
            headers: const <String, String>{
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            // No model, credential, prompt, or upstream URL is sent by Web.
            body: jsonEncode(<String, Object>{
              'version': 1,
              'capability': 'orchestration',
              'selfTest': true,
              if (routeId != null &&
                  RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$').hasMatch(routeId))
                'routeId': routeId,
            }),
          )
          .timeout(timeout);

      dynamic decoded;
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        return WorkshopWebCloudSelfTestResult(
          passed: false,
          detail: 'Risposta non JSON dal broker (controllare Access e rete).',
          elapsed: stopwatch.elapsed,
          statusCode: response.statusCode,
        );
      }

      if (response.statusCode != 200) {
        final error = decoded is Map ? decoded['error'] : null;
        final code = error is Map ? error['code'] : null;
        final notConfigured = code == 'self_test_not_configured';
        return WorkshopWebCloudSelfTestResult(
          passed: false,
          detail: notConfigured
              ? 'Self-Test non configurato: autorizzare sul server una rotta '
                  'verificata a costo zero (selfTestFree=true).'
              : 'Il broker ha risposto con HTTP ${response.statusCode}'
                  '${code is String ? ' ($code)' : ''}.',
          elapsed: stopwatch.elapsed,
          statusCode: response.statusCode,
          errorCode: code is String ? code : null,
        );
      }

      if (decoded is! Map || decoded['version'] != 1) {
        return WorkshopWebCloudSelfTestResult(
          passed: false,
          detail: 'Formato del risultato non valido.',
          elapsed: stopwatch.elapsed,
          statusCode: response.statusCode,
        );
      }

      final text = _text(decoded['text']);
      final provider = _text(decoded['provider']);
      final configuredModel = _text(decoded['model']);
      final reportedModel = _text(decoded['reportedModel']);
      final routeId = _text(decoded['routeId']);
      final tokens = decoded['tokensGenerated'];
      final markerMatches = text == expectedMarker;
      // The configured model alone does not prove the responding model.
      final attributionComplete =
          provider != null && reportedModel != null && routeId != null;
      final passed = markerMatches && attributionComplete;

      return WorkshopWebCloudSelfTestResult(
        passed: passed,
        detail: !markerMatches
            ? 'Il modello non ha restituito esattamente il testo di prova.'
            : !attributionComplete
                ? 'Testo corretto, ma provider/modello effettivo non '
                    'attribuibili completamente.'
                : 'Testo di prova corretto e risposta attribuita.',
        elapsed: stopwatch.elapsed,
        statusCode: response.statusCode,
        provider: provider,
        configuredModel: configuredModel,
        reportedModel: reportedModel,
        routeId: routeId,
        tokensGenerated: tokens is int && tokens >= 0 ? tokens : null,
      );
    } on TimeoutException {
      return WorkshopWebCloudSelfTestResult(
        passed: false,
        detail: 'Timeout del broker Web.',
        elapsed: stopwatch.elapsed,
      );
    } on Object {
      return WorkshopWebCloudSelfTestResult(
        passed: false,
        detail: 'Il browser non riesce a raggiungere il broker Web.',
        elapsed: stopwatch.elapsed,
      );
    } finally {
      stopwatch.stop();
    }
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final result = value.trim();
    return result.isEmpty || result.length > 200 ? null : result;
  }
}
