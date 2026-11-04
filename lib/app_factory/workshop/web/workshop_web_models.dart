import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Read-only, sanitized view of actual server routes. Never contains URLs,
/// keys, secret names or request authorization. The server remains authoritative.
final class WorkshopWebModelRoute {
  const WorkshopWebModelRoute({
    required this.routeId,
    required this.model,
    required this.provider,
    required this.bindingPresent,
    required this.testApproved,
    required this.selectable,
  });

  final String routeId;
  final String model;
  final String provider;
  final bool bindingPresent;
  final bool testApproved;
  final bool selectable;

  static WorkshopWebModelRoute? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['routeId'];
    final model = raw['model'];
    final provider = raw['provider'];
    if (id is! String ||
        !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$').hasMatch(id) ||
        model is! String || model.isEmpty || model.length > 200 ||
        provider is! String || provider.isEmpty || provider.length > 50) {
      return null;
    }
    return WorkshopWebModelRoute(
      routeId: id,
      model: model,
      provider: provider,
      bindingPresent: raw['bindingPresent'] == true,
      testApproved: raw['testApproved'] == true,
      selectable: raw['selectable'] == true &&
          raw['bindingPresent'] == true &&
          raw['testApproved'] == true,
    );
  }
}

final class WorkshopWebModelCatalogue {
  const WorkshopWebModelCatalogue({
    required this.configStatus,
    required this.models,
    this.httpStatus,
    this.errorCode,
  });

  final String configStatus;
  final List<WorkshopWebModelRoute> models;
  final int? httpStatus;
  final String? errorCode;
  bool get hasTestRoutes => models.any((route) => route.selectable);
}

final class WorkshopWebModelCatalogueClient {
  WorkshopWebModelCatalogueClient({
    http.Client? client,
    Uri? baseUri,
    this.timeout = const Duration(seconds: 15),
  })  : _client = client ?? http.Client(),
        _baseUri = baseUri ?? Uri.base;

  final http.Client _client;
  final Uri _baseUri;
  final Duration timeout;

  Future<WorkshopWebModelCatalogue> load() async {
    try {
      final response = await _client.get(
        _baseUri.resolve('/api/cantiere/models'),
        headers: const <String, String>{'Accept': 'application/json'},
      ).timeout(timeout);
      if (response.statusCode != 200) {
        return WorkshopWebModelCatalogue(
          configStatus: 'unavailable',
          models: const [],
          httpStatus: response.statusCode,
          errorCode: 'http_${response.statusCode}',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map ||
          decoded['version'] != 1 ||
          decoded['capability'] != 'orchestration' ||
          decoded['models'] is! List) {
        return const WorkshopWebModelCatalogue(
          configStatus: 'invalid',
          models: [],
          errorCode: 'invalid_payload',
        );
      }
      final rows = (decoded['models'] as List)
          .take(20)
          .map(WorkshopWebModelRoute.fromJson)
          .whereType<WorkshopWebModelRoute>()
          .toList(growable: false);
      final status = decoded['configStatus'];
      return WorkshopWebModelCatalogue(
        configStatus: status is String ? status : 'unknown',
        models: rows,
        httpStatus: response.statusCode,
      );
    } on TimeoutException {
      return const WorkshopWebModelCatalogue(
        configStatus: 'unavailable', models: [], errorCode: 'timeout',
      );
    } on Object {
      return const WorkshopWebModelCatalogue(
        configStatus: 'unavailable', models: [], errorCode: 'unreachable',
      );
    }
  }
}

/// Only an opaque route ID is kept in the browser. It never grants access:
/// the Pages Function checks the binding and testApproved flag on each call.
final class WorkshopWebModelPreference extends ChangeNotifier {
  WorkshopWebModelPreference({
    String? routeId,
    SharedPreferences? preferences,
  }) : _routeId = validId(routeId) ? routeId : null,
       _preferences = preferences;

  static const String storageKey = 'aivexus.web.model_route.v1';
  final SharedPreferences? _preferences;
  String? _routeId;

  String? get routeId => _routeId;
  bool get automatic => _routeId == null;

  static bool validId(String? id) =>
      id != null &&
      RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$').hasMatch(id);

  static Future<WorkshopWebModelPreference> open() async {
    final prefs = await SharedPreferences.getInstance();
    return WorkshopWebModelPreference(
      routeId: prefs.getString(storageKey), preferences: prefs,
    );
  }

  Future<void> select(WorkshopWebModelRoute? route) async {
    if (route != null && (!route.selectable || !validId(route.routeId))) {
      return;
    }
    final next = route?.routeId;
    if (_routeId == next) return;
    _routeId = next;
    notifyListeners();
    if (next == null) {
      await _preferences?.remove(storageKey);
    } else {
      await _preferences?.setString(storageKey, next);
    }
  }

  /// Clear a stale stored choice as soon as a fresh catalogue rejects it.
  Future<void> reconcile(WorkshopWebModelCatalogue catalogue) async {
    final id = _routeId;
    if (id != null &&
        catalogue.errorCode == null &&
        !catalogue.models.any((r) => r.routeId == id && r.selectable)) {
      await select(null);
    }
  }
}
