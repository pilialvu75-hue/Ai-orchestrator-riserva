// AppLegalCore — Legal state model.
//
// Persisted as JSON in SharedPreferences. The [eulaVersion] field drives
// the version-bump re-prompt logic: whenever [EulaService.currentEulaVersion]
// exceeds the saved version the user is shown the EULA again.

import 'package:equatable/equatable.dart';

class LegalState extends Equatable {
  const LegalState({
    required this.eulaAccepted,
    required this.eulaVersion,
    required this.acceptedAt,
  });

  /// Whether the user has accepted the current (or any previous) EULA.
  final bool eulaAccepted;

  /// The EULA version that was accepted.
  final int eulaVersion;

  /// UTC timestamp of when the EULA was accepted. Null if never accepted.
  final DateTime? acceptedAt;

  // ── Factory constructors ──────────────────────────────────────────────────

  /// Default state for a first-run user who has not yet accepted anything.
  const LegalState.initial()
      : eulaAccepted = false,
        eulaVersion = 0,
        acceptedAt = null;

  factory LegalState.fromJson(Map<String, dynamic> json) {
    return LegalState(
      eulaAccepted: json['eulaAccepted'] as bool? ?? false,
      eulaVersion: json['eulaVersion'] as int? ?? 0,
      acceptedAt: json['acceptedAt'] != null
          ? DateTime.tryParse(json['acceptedAt'] as String)
          : null,
    );
  }

  // ── Serialisation ─────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'eulaAccepted': eulaAccepted,
        'eulaVersion': eulaVersion,
        'acceptedAt': acceptedAt?.toUtc().toIso8601String(),
      };

  LegalState copyWith({
    bool? eulaAccepted,
    int? eulaVersion,
    DateTime? acceptedAt,
  }) {
    return LegalState(
      eulaAccepted: eulaAccepted ?? this.eulaAccepted,
      eulaVersion: eulaVersion ?? this.eulaVersion,
      acceptedAt: acceptedAt ?? this.acceptedAt,
    );
  }

  @override
  List<Object?> get props => [eulaAccepted, eulaVersion, acceptedAt];
}
