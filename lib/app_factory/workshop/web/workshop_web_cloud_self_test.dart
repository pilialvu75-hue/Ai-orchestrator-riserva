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
    this.failureKind,
    this.upstreamStatus,
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
  final String? failureKind;
  final int? upstreamStatus;
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

  Future<WorkshopWebCloudSelfTestResult> run({String? selectedRouteId}) async {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _client
          .post(
            endpoint,
            headers: const <String, String>{
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              // Ask Cloudflare Access to return HTTP 401 instead of a
              // redirect/login HTML for expired browser sessions.
              'X-Requested-With': 'XMLHttpRequest',
            },
            // No model, credential, prompt, or upstream URL is sent by Web.
            body: jsonEncode(<String, Object>{
              'version': 1,
              'capability': 'orchestration',
              'selfTest': true,
              if (selectedRouteId != null &&
                  RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$').hasMatch(selectedRouteId))
                'routeId': selectedRouteId,
            }),
          )
          .timeout(timeout);

      // Pages Functions do not issue 401: an unauthenticated response here
      // comes from Cloudflare Access, before any NVIDIA route is invoked.
      if (response.statusCode == 401) {
        return WorkshopWebCloudSelfTestResult(
          passed: false,
          detail: 'Accesso Cloudflare scaduto o non autenticato: riaprire '
              'https://aivexus.pages.dev ed eseguire un nuovo login.',
          elapsed: stopwatch.elapsed,
          statusCode: 401,
          errorCode: 'access_login_required',
        );
      }

      dynamic decoded;
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        final isHtml =
            (response.headers['content-type'] ?? '').toLowerCase().contains('text/html');
        return WorkshopWebCloudSelfTestResult(
          passed: false,
          detail: isHtml
              ? 'Il broker ha ricevuto HTML anziché JSON: possibile pagina '
                  'Cloudflare Access. Verificare la sessione e rifare il login.'
              : 'Risposta non JSON dal broker (controllare Access e rete).',
          elapsed: stopwatch.elapsed,
          statusCode: response.statusCode,
          errorCode: isHtml ? 'possible_access_login' : 'invalid_json',
        );
      }

      if (response.statusCode != 200) {
        final error = decoded is Map ? decoded['error'] : null;
        final code = error is Map ? error['code'] : null;
        final notConfigured = code == 'self_test_not_configured';
        final reason = error is Map ? error['failureKind'] : null;
        const allowedReasons = <String>{
          'binding_missing',
          'pending_response_unresolved',
          'upstream_http_rejection',
          'upstream_invalid_json',
          'no_final_text',
          'output_token_limit',
          'upstream_timeout',
          'upstream_connection_error',
          'upstream_unknown',
        };
        final failureKind = reason is String && allowedReasons.contains(reason)
            ? reason
            : null;
        final upstream = error is Map ? error['upstreamStatus'] : null;
        final failedRoute = error is Map ? error['routeId'] : null;
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
          failureKind: failureKind,
          upstreamStatus: upstream is int && upstream >= 400 && upstream <= 599
              ? upstream
              : null,
          routeId: failedRoute is String &&
                  RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$').hasMatch(failedRoute)
              ? failedRoute
              : null,
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
            ? (decoded['text'] is String &&
                      (decoded['text'] as String).trim().isNotEmpty
                  ? 'Il modello ha restituito un testo finale, ma non esattamente il '
                      'marcatore richiesto: inferenza presente, Self-Test non superato.'
                  : 'Nessun testo finale valido nel risultato del broker.')
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
