import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'workshop_airlab_contract.dart';

class WorkshopAirLabException implements Exception {
  const WorkshopAirLabException(
    this.message, {
    this.statusCode,
    this.code,
  });

  final String message;
  final int? statusCode;
  final String? code;

  @override
  String toString() => 'WorkshopAirLabException($statusCode, $code, $message)';
}

/// Browser-safe HTTP client for the AIrLab service.
///
/// The client deliberately has no knowledge of llama.cpp, GPUs, NAS nodes or
/// Cloud providers. Cantiere sees one stable AIrLab contract regardless of
/// where the future model engine is hosted.
class WorkshopAirLabClient {
  WorkshopAirLabClient({
    required Uri baseUri,
    required http.Client httpClient,
    this.timeout = const Duration(seconds: 4),
    String? authToken,
  })  : _baseUri = _normalizeBaseUri(baseUri),
        _httpClient = httpClient,
        _authToken = authToken?.trim().isEmpty == true ? null : authToken?.trim();

  final Uri _baseUri;
  final http.Client _httpClient;
  final Duration timeout;
  final String? _authToken;

  Future<WorkshopAirLabProbe> probe() async {
    try {
      final json = await _getJson('health');
      final service = json['service'];
      final engineId = json['engine_id'];
      if (service != 'airlab' || engineId is! String || engineId.trim().isEmpty) {
        return const WorkshopAirLabProbe(
          availability: WorkshopAirLabAvailability.incompatible,
          reason: 'Unexpected AIrLab health payload.',
        );
      }
      return WorkshopAirLabProbe(
        availability: WorkshopAirLabAvailability.available,
        engineId: engineId,
      );
    } on TimeoutException {
      return const WorkshopAirLabProbe(
        availability: WorkshopAirLabAvailability.unavailable,
        reason: 'AIrLab health probe timed out.',
      );
    } on http.ClientException catch (error) {
      return WorkshopAirLabProbe(
        availability: WorkshopAirLabAvailability.unavailable,
        reason: error.message,
      );
    } on WorkshopAirLabException catch (error) {
      return WorkshopAirLabProbe(
        availability: error.statusCode != null && error.statusCode! >= 500
            ? WorkshopAirLabAvailability.unavailable
            : WorkshopAirLabAvailability.incompatible,
        reason: error.message,
      );
    } on FormatException catch (error) {
      return WorkshopAirLabProbe(
        availability: WorkshopAirLabAvailability.incompatible,
        reason: error.message,
      );
    }
  }

  Future<WorkshopAirLabCapabilities> capabilities() async {
    try {
      final json = await _getJson('v1/capabilities');
      final capabilities = WorkshopAirLabCapabilities.fromJson(json);
      if (capabilities.service != 'airlab') {
        throw const WorkshopAirLabException(
          'Endpoint does not identify itself as AIrLab.',
          code: 'incompatible_service',
        );
      }
      return capabilities;
    } on TimeoutException {
      throw const WorkshopAirLabException(
        'AIrLab capability request timed out.',
        code: 'transport_timeout',
      );
    } on http.ClientException catch (error) {
      throw WorkshopAirLabException(
        'AIrLab capability request is unavailable: ${error.message}',
        code: 'transport_unavailable',
      );
    }
  }

  Future<WorkshopAirLabTaskResponse> submitTask(
    WorkshopAirLabTaskRequest request,
  ) async {
    try {
      final json = await _postJson('v1/tasks', request.toJson());
      return WorkshopAirLabTaskResponse.fromJson(json);
    } on TimeoutException {
      throw const WorkshopAirLabException(
        'AIrLab task request timed out.',
        code: 'transport_timeout',
      );
    } on http.ClientException catch (error) {
      throw WorkshopAirLabException(
        'AIrLab task request is unavailable: ${error.message}',
        code: 'transport_unavailable',
      );
    }
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final response = await _httpClient
        .get(_baseUri.resolve(path), headers: _headers())
        .timeout(timeout);
    return _decode(response);
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final response = await _httpClient
        .post(
          _baseUri.resolve(path),
          headers: _headers(contentTypeJson: true),
          body: jsonEncode(payload),
        )
        .timeout(timeout);
    return _decode(response);
  }

  Map<String, String> _headers({bool contentTypeJson = false}) {
    return <String, String>{
      'Accept': 'application/json',
      if (contentTypeJson) 'Content-Type': 'application/json',
      if (_authToken != null) 'Authorization': 'Bearer $_authToken',
    };
  }

  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const FormatException('AIrLab response must be a JSON object.');
      }
      json = Map<String, dynamic>.from(decoded);
    } on FormatException {
      rethrow;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WorkshopAirLabException(
        json['error']?.toString() ?? 'AIrLab request failed.',
        statusCode: response.statusCode,
        code: json['code']?.toString(),
      );
    }
    return json;
  }

  static Uri _normalizeBaseUri(Uri value) {
    final text = value.toString();
    return text.endsWith('/') ? value : Uri.parse('$text/');
  }
}
