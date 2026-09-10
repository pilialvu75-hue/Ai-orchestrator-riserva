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

/// User-managed Cloud provider profiles plus a small immutable system registry
/// for provider-neutral, OpenAI-compatible Free Intelligence Pool routes.
///
/// Only user-created metadata is persisted here. API keys remain in
/// [CloudCredentialStore] and therefore use encrypted device storage.
/// System profiles are not exposed through [profiles], so the Settings editor
/// cannot delete or mutate the built-in compatible routes.
final class CustomCloudProviderStore extends ChangeNotifier {
  CustomCloudProviderStore._();

  static final CustomCloudProviderStore instance = CustomCloudProviderStore._();

  static const String _storageKey = 'cloud.custom.providers.v1';
  static const int _maxProfiles = 24;

  /// These providers deliberately use the same generic OpenAI-compatible
  /// executor as user-created profiles. That keeps transport wiring
  /// provider-neutral while CloudProviderCatalog remains the source of truth
  /// for access/cost classification and routing policy.
  static const Map<String, CustomCloudProviderProfile> _systemProfiles =
      <String, CustomCloudProviderProfile>{
    'groq': CustomCloudProviderProfile(
      id: 'groq',
      displayName: 'Groq',
      endpoint: 'https://api.groq.com/openai/v1/chat/completions',
      defaultModel: 'qwen/qwen3.8-27b',
      protocol: CustomCloudProviderProtocol.openAiCompatible,
      billing: CustomCloudProviderBilling.free,
    ),
    'nvidiaNim': CustomCloudProviderProfile(
      id: 'nvidiaNim',
      displayName: 'NVIDIA NIM',
      endpoint: 'https://integrate.api.nvidia.com/v1/chat/completions',
      defaultModel: 'meta/llama-3.1-8b-instruct',
      protocol: CustomCloudProviderProtocol.openAiCompatible,
      billing: CustomCloudProviderBilling.free,
    ),
    'mistral': CustomCloudProviderProfile(
      id: 'mistral',
      displayName: 'Mistral',
      endpoint: 'https://api.mistral.ai/v1/chat/completions',
      defaultModel: 'mistral-small-latest',
      protocol: CustomCloudProviderProtocol.openAiCompatible,
      billing: CustomCloudProviderBilling.free,
    ),
    'openRouter': CustomCloudProviderProfile(
      id: 'openRouter',
      displayName: 'OpenRouter Free Pool',
      endpoint: 'https://openrouter.ai/api/v1/chat/completions',
      defaultModel: 'openrouter/free',
      protocol: CustomCloudProviderProtocol.openAiCompatible,
      billing: CustomCloudProviderBilling.free,
    ),
  };

  SharedPreferences? _preferences;
  final List<CustomCloudProviderProfile> _profiles =
      <CustomCloudProviderProfile>[];

  bool get isInitialized => _preferences != null;

  /// User-created profiles only. System profiles are intentionally excluded so
  /// the custom-provider management UI cannot delete or edit them.
  List<CustomCloudProviderProfile> get profiles =>
      List<CustomCloudProviderProfile>.unmodifiable(_profiles);

  List<String> get providerIds => <String>[
        ..._systemProfiles.keys,
        ..._profiles.map((profile) => profile.id),
      ];

  Future<void> initialize({SharedPreferences? preferences}) async {
    _preferences = preferences ?? await SharedPreferences.getInstance();
    _profiles
      ..clear()
      ..addAll(_decodeProfiles(_preferences!.getString(_storageKey)));
  }

  CustomCloudProviderProfile? profileFor(String providerId) {
    final normalized = providerId.trim();
    final system = _systemProfiles[normalized];
    if (system != null) return system;
    for (final profile in _profiles) {
      if (profile.id == normalized) return profile;
    }
    return null;
  }

  bool contains(String providerId) => profileFor(providerId) != null;

  bool isSystemProfile(String providerId) =>
      _systemProfiles.containsKey(providerId.trim());

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
    if (isSystemProfile(profile.id)) {
      throw ArgumentError.value(
        profile.id,
        'id',
        'System Cloud providers cannot be edited.',
      );
    }
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
    if (isSystemProfile(providerId)) {
      throw ArgumentError.value(
        providerId,
        'providerId',
        'System Cloud providers cannot be removed.',
      );
    }
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
