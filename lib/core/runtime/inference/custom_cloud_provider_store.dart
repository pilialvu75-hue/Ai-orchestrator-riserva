import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum CustomCloudProviderProtocol {
  openAiCompatible,
  anthropicCompatible,
  geminiCompatible,
}

enum CustomCloudProviderBilling {
  free,
  paid,
}

class CustomCloudProviderProfile {
  const CustomCloudProviderProfile({
    required this.id,
    required this.displayName,
    required this.endpoint,
    required this.defaultModel,
    required this.protocol,
    required this.billing,
  });

  final String id;
  final String displayName;
  final String endpoint;
  final String defaultModel;
  final CustomCloudProviderProtocol protocol;
  final CustomCloudProviderBilling billing;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'displayName': displayName,
        'endpoint': endpoint,
        'defaultModel': defaultModel,
        'protocol': protocol.name,
        'billing': billing.name,
      };

  factory CustomCloudProviderProfile.fromJson(Map<String, dynamic> json) {
    final protocolName = json['protocol']?.toString() ?? '';
    final billingName = json['billing']?.toString() ?? '';

    final protocol = CustomCloudProviderProtocol.values.where(
      (value) => value.name == protocolName,
    );
    final billing = CustomCloudProviderBilling.values.where(
      (value) => value.name == billingName,
    );

    if (protocol.isEmpty || billing.isEmpty) {
      throw const FormatException('Unsupported custom provider profile.');
    }

    return CustomCloudProviderProfile(
      id: json['id']?.toString() ?? '',
      displayName: json['displayName']?.toString() ?? '',
      endpoint: json['endpoint']?.toString() ?? '',
      defaultModel: json['defaultModel']?.toString() ?? '',
      protocol: protocol.first,
      billing: billing.first,
    );
  }
}

/// User-managed Cloud provider profiles.
///
/// Only non-secret metadata is stored here. API keys remain in
/// [CloudCredentialStore] and therefore use encrypted device storage.
/// A profile lets future OpenAI/Anthropic/Gemini-compatible providers be added
/// from Settings without shipping a new app build.
final class CustomCloudProviderStore extends ChangeNotifier {
  CustomCloudProviderStore._();

  static final CustomCloudProviderStore instance = CustomCloudProviderStore._();

  static const String _storageKey = 'cloud.custom.providers.v1';
  static const int _maxProfiles = 24;

  SharedPreferences? _preferences;
  final List<CustomCloudProviderProfile> _profiles =
      <CustomCloudProviderProfile>[];

  bool get isInitialized => _preferences != null;

  List<CustomCloudProviderProfile> get profiles =>
      List<CustomCloudProviderProfile>.unmodifiable(_profiles);

  List<String> get providerIds =>
      _profiles.map((profile) => profile.id).toList(growable: false);

  Future<void> initialize({SharedPreferences? preferences}) async {
    _preferences = preferences ?? await SharedPreferences.getInstance();
    _profiles
      ..clear()
      ..addAll(_decodeProfiles(_preferences!.getString(_storageKey)));
  }

  CustomCloudProviderProfile? profileFor(String providerId) {
    final normalized = providerId.trim();
    for (final profile in _profiles) {
      if (profile.id == normalized) return profile;
    }
    return null;
  }

  bool contains(String providerId) => profileFor(providerId) != null;

  Future<CustomCloudProviderProfile> create({
    required String displayName,
    required String endpoint,
    required String defaultModel,
    required CustomCloudProviderProtocol protocol,
    required CustomCloudProviderBilling billing,
  }) async {
    _ensureInitialized();
    if (_profiles.length >= _maxProfiles) {
      throw StateError('Maximum number of custom Cloud providers reached.');
    }

    final normalizedName = displayName.trim();
    final normalizedEndpoint = _validateEndpoint(endpoint);
    final normalizedModel = defaultModel.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(displayName, 'displayName', 'Name is required.');
    }
    if (normalizedModel.isEmpty) {
      throw ArgumentError.value(defaultModel, 'defaultModel', 'Model is required.');
    }

    final slug = normalizedName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final id = 'custom_${slug.isEmpty ? 'provider' : slug}_$suffix';

    final profile = CustomCloudProviderProfile(
      id: id,
      displayName: normalizedName,
      endpoint: normalizedEndpoint,
      defaultModel: normalizedModel,
      protocol: protocol,
      billing: billing,
    );
    _profiles.add(profile);
    await _persist();
    notifyListeners();
    return profile;
  }

  Future<void> update(CustomCloudProviderProfile profile) async {
    _ensureInitialized();
    final index = _profiles.indexWhere((item) => item.id == profile.id);
    if (index < 0) {
      throw ArgumentError.value(profile.id, 'id', 'Unknown custom provider.');
    }

    final normalized = CustomCloudProviderProfile(
      id: profile.id,
      displayName: profile.displayName.trim(),
      endpoint: _validateEndpoint(profile.endpoint),
      defaultModel: profile.defaultModel.trim(),
      protocol: profile.protocol,
      billing: profile.billing,
    );
    if (normalized.displayName.isEmpty || normalized.defaultModel.isEmpty) {
      throw const FormatException('Custom provider name/model cannot be empty.');
    }

    _profiles[index] = normalized;
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String providerId) async {
    _ensureInitialized();
    _profiles.removeWhere((profile) => profile.id == providerId);
    await _persist();
    notifyListeners();
  }

  String protocolLabel(CustomCloudProviderProtocol protocol) {
    switch (protocol) {
      case CustomCloudProviderProtocol.openAiCompatible:
        return 'OpenAI-compatible';
      case CustomCloudProviderProtocol.anthropicCompatible:
        return 'Anthropic-compatible';
      case CustomCloudProviderProtocol.geminiCompatible:
        return 'Gemini-compatible';
    }
  }

  String billingLabel(CustomCloudProviderBilling billing) {
    switch (billing) {
      case CustomCloudProviderBilling.free:
        return 'Free';
      case CustomCloudProviderBilling.paid:
        return 'Paid';
    }
  }

  List<CustomCloudProviderProfile> _decodeProfiles(String? encoded) {
    if (encoded == null || encoded.trim().isEmpty) {
      return const <CustomCloudProviderProfile>[];
    }
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return const <CustomCloudProviderProfile>[];
      final result = <CustomCloudProviderProfile>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final profile = CustomCloudProviderProfile.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (profile.id.startsWith('custom_') &&
            profile.displayName.trim().isNotEmpty &&
            profile.defaultModel.trim().isNotEmpty &&
            _isAllowedEndpoint(profile.endpoint)) {
          result.add(profile);
        }
      }
      return result.take(_maxProfiles).toList(growable: false);
    } catch (_) {
      return const <CustomCloudProviderProfile>[];
    }
  }

  Future<void> _persist() async {
    final preferences = _preferences;
    if (preferences == null) {
      throw StateError('CustomCloudProviderStore is not initialized.');
    }
    await preferences.setString(
      _storageKey,
      jsonEncode(_profiles.map((profile) => profile.toJson()).toList()),
    );
  }

  String _validateEndpoint(String value) {
    final endpoint = value.trim();
    if (!_isAllowedEndpoint(endpoint)) {
      throw ArgumentError.value(
        value,
        'endpoint',
        'Use HTTPS, or HTTP only for localhost/127.0.0.1.',
      );
    }
    return endpoint;
  }

  bool _isAllowedEndpoint(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return false;
    if (uri.scheme.toLowerCase() == 'https') return true;
    if (uri.scheme.toLowerCase() != 'http') return false;
    final host = uri.host.toLowerCase();
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  void _ensureInitialized() {
    if (_preferences == null) {
      throw StateError('CustomCloudProviderStore is not initialized.');
    }
  }
}
