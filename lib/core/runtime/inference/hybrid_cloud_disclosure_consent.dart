import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'hybrid_checkpoint_snapshot_store.dart';

/// Source of each precise section that would leave the device.
/// These labels MUST come from a trusted prompt assembler, never from a
/// model's untrusted claims about the sensitivity of its own output.
enum HybridDisclosureOrigin {
  currentQuestion,
  systemInstructions,
  conversationHistory,
  durableMemory,
  documentExcerpt,
  attachment,
  toolResult,
}

/// Sensitivity is independent of origin: a chat turn, document or preference
/// can itself contain particularly sensitive personal data. Unknown is the
/// conservative default; it cannot gain a persistent automatic allowance.
enum HybridDisclosureSensitivity {
  publicOrNonPersonal,
  preference,
  personal,
  confidential,
  highlySensitive,
  unknown,
}

final class HybridDisclosureScope {
  const HybridDisclosureScope(this.origin, this.sensitivity);

  final HybridDisclosureOrigin origin;
  final HybridDisclosureSensitivity sensitivity;

  @override
  bool operator ==(Object other) =>
      other is HybridDisclosureScope &&
      origin == other.origin &&
      sensitivity == other.sensitivity;

  @override
  int get hashCode => Object.hash(origin, sensitivity);
}

final class HybridDisclosureSegment {
  const HybridDisclosureSegment({
    required this.text,
    required this.scope,
  });

  /// Exact bytes/characters the trusted assembler intends to send.
  final String text;
  final HybridDisclosureScope scope;
}

/// No "sidecar" segment list is trusted: the protected gate must check that
/// the concatenation of classified segments is EXACTLY the outbound prompt.
/// This also covers previous chat turns, document extracts, current question
/// and system instructions rather than protecting only durable memories.
final class HybridCloudDisclosure {
  HybridCloudDisclosure({
    required this.ownerId,
    required this.sessionId,
    required this.providerId,
    required this.purpose,
    required this.outboundText,
    required List<HybridDisclosureSegment> segments,
  }) : segments = List<HybridDisclosureSegment>.unmodifiable(segments) {
    if (ownerId.trim().isEmpty ||
        ownerId != ownerId.trim() ||
        ownerId.length > 256 ||
        sessionId.trim().isEmpty ||
        sessionId != sessionId.trim() ||
        sessionId.length > 256 ||
        !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$')
            .hasMatch(providerId) ||
        purpose.trim().isEmpty ||
        purpose.length > 256 ||
        outboundText.isEmpty ||
        outboundText.length > maxOutboundCharacters ||
        this.segments.isEmpty ||
        this.segments.length > maxSegments ||
        this.segments.any((segment) => segment.text.isEmpty) ||
        this.segments.map((segment) => segment.text).join() != outboundText) {
      throw ArgumentError('Untrusted or incomplete HYBRID Cloud disclosure');
    }
  }

  static const int maxOutboundCharacters = 32 * 1024;
  static const int maxSegments = 64;

  final String ownerId;
  final String sessionId;
  final String providerId;
  final String purpose;
  final String outboundText;
  final List<HybridDisclosureSegment> segments;

  List<HybridDisclosureScope> get scopes =>
      segments.map((segment) => segment.scope).toSet().toList(growable: false);

  /// Binds a one-shot UI review to an exact outgoing prompt and destination.
  /// This digest is not a secret or a replacement for consent.
  String get contentFingerprint => sha256.convert(utf8.encode(jsonEncode(
        <String>[ownerId, sessionId, providerId, purpose, outboundText],
      ))).toString();
}

/// A dialog response for ONE destination and exact outgoing prompt.
///
/// allowOnce: permit this prompt only (no persistent preference).
/// allowAlways: persist opt-in for this provider + source + sensitivity.
/// allowAndAskNextTime: permit now, but record "ask every time" thereafter.
/// denyOnce: do not send this prompt, do not persist.
/// neverShare: persist a deny rule, revocable in settings.
enum HybridCloudConsentChoice {
  allowOnce,
  allowAlways,
  allowAndAskNextTime,
  denyOnce,
  neverShare,
}

enum HybridCloudStoredConsent {
  allowAlways,
  askEveryTime,
  neverShare,
}

/// Consumer UI MUST display provider, reason, scopes and the actual outbound
/// text or a trustworthy inspection of every included segment. No blanket
/// approval for all providers or all personal data is implied by Cloud mode.
final class HybridCloudConsentReview {
  const HybridCloudConsentReview({
    required this.disclosure,
    required this.needsConsent,
  });

  final HybridCloudDisclosure disclosure;
  final List<HybridDisclosureScope> needsConsent;

  String get fingerprint => disclosure.contentFingerprint;
}

/// Opt-in, fail-closed consent contract for Cloud data disclosures.
///
/// Preferences are per owner, provider, origin and sensitivity, persisted in
/// the same OS-protected storage abstraction used by HYBRID checkpoints.
/// The stored rules contain NO raw prompt, document, memory or secret.
/// They are *not* a login, a chat widget or the final Cloud dispatch gate.
///
/// The existing runner must still approve the exact outbound text, check
/// provider spending policies at dispatch, and ensure that this classified
/// prompt is the identical text eventually sent. Never infer consent solely
/// from selecting the HYBRID or Cloud runtime mode.
final class HybridCloudDisclosureConsent {
  HybridCloudDisclosureConsent({
    required HybridProtectedSnapshotBackend backend,
    required Future<bool> Function(String ownerId, String sessionId)
        authorizeOwnerSession,
  })  : _backend = backend,
        _authorizeOwnerSession = authorizeOwnerSession;

  final HybridProtectedSnapshotBackend _backend;
  final Future<bool> Function(String ownerId, String sessionId)
      _authorizeOwnerSession;
  Future<void> _tail = Future<void>.value();

  static const String _prefix = 'hybrid_cloud_consent_v1_';

  Future<bool> authorize({
    required HybridCloudDisclosure disclosure,
    Future<Map<HybridDisclosureScope, HybridCloudConsentChoice>> Function(
      HybridCloudConsentReview review,
    )? requestConsent,
  }) => _serialize(() async {
        if (!await _authorizeOwnerSession(
          disclosure.ownerId, disclosure.sessionId,
        )) {
          return false;
        }

        final unapproved = <HybridDisclosureScope>[];
        for (final scope in disclosure.scopes) {
          final rule = await _readRule(disclosure.ownerId,
              disclosure.providerId, scope);
          if (rule == HybridCloudStoredConsent.neverShare) return false;
          if (rule != HybridCloudStoredConsent.allowAlways ||
              scope.sensitivity == HybridDisclosureSensitivity.unknown) {
            unapproved.add(scope);
          }
        }
        if (unapproved.isEmpty) return true;
        if (requestConsent == null) return false;

        // A user dialog can suspend for arbitrarily long. Revalidate session
        // ownership afterward, before recording rules or allowing any send.
        final decisions = await requestConsent(HybridCloudConsentReview(
          disclosure: disclosure,
          needsConsent: List<HybridDisclosureScope>.unmodifiable(unapproved),
        ));
        if (!await _authorizeOwnerSession(
          disclosure.ownerId, disclosure.sessionId,
        )) {
          return false;
        }
        if (decisions.length != unapproved.length ||
            !unapproved.every(decisions.containsKey)) {
          return false; // Incomplete UI responses never imply approval.
        }

        var canSend = true;
        for (final scope in unapproved) {
          final decision = decisions[scope]!;
          switch (decision) {
            case HybridCloudConsentChoice.allowOnce:
              break;
            case HybridCloudConsentChoice.allowAlways:
              if (scope.sensitivity == HybridDisclosureSensitivity.unknown) {
                return false; // Unclassified context must be reviewed anew.
              }
              await _writeRule(disclosure.ownerId,
                  disclosure.providerId, scope,
                  HybridCloudStoredConsent.allowAlways);
            case HybridCloudConsentChoice.allowAndAskNextTime:
              await _writeRule(disclosure.ownerId,
                  disclosure.providerId, scope,
                  HybridCloudStoredConsent.askEveryTime);
            case HybridCloudConsentChoice.denyOnce:
              canSend = false;
            case HybridCloudConsentChoice.neverShare:
              await _writeRule(disclosure.ownerId,
                  disclosure.providerId, scope,
                  HybridCloudStoredConsent.neverShare);
              canSend = false;
          }
        }
        // All consent choices are scoped to THIS exact outbound disclosure.
        return canSend;
      });

  /// Used by a settings/consent-management UI. Explicit user action only.
  /// Revocation changes a remembered allow to no automatic consent.
  Future<void> revoke({
    required String ownerId,
    required String sessionId,
    required String providerId,
    required HybridDisclosureScope scope,
  }) => _serialize(() async {
        if (!await _authorizeOwnerSession(ownerId, sessionId)) {
          throw StateError('HYBRID consent owner/session is not authorized');
        }
        final key = _key(ownerId, providerId, scope);
        await _backend.delete(key);
        if (await _backend.read(key) != null) {
          throw StateError('HYBRID Cloud consent revocation not confirmed');
        }
      });

  Future<HybridCloudStoredConsent?> storedPreference({
    required String ownerId,
    required String sessionId,
    required String providerId,
    required HybridDisclosureScope scope,
  }) => _serialize(() async {
        if (!await _authorizeOwnerSession(ownerId, sessionId)) {
          throw StateError('HYBRID consent owner/session is not authorized');
        }
        return _readRule(ownerId, providerId, scope);
      });

  Future<HybridCloudStoredConsent?> _readRule(
    String owner, String provider, HybridDisclosureScope scope,
  ) async {
    final raw = await _backend.read(_key(owner, provider, scope));
    if (raw == null) return null;
    if (raw.length > 1024) {
      throw const FormatException('Oversized HYBRID consent rule');
    }
    final value = jsonDecode(raw);
    if (value is! Map ||
        value['version'] != 1 ||
        value['ownerDigest'] != _digest(owner) ||
        value['provider'] != provider ||
        value['origin'] != scope.origin.name ||
        value['sensitivity'] != scope.sensitivity.name ||
        value['rule'] is! String) {
      throw const FormatException('Invalid HYBRID consent rule');
    }
    for (final candidate in HybridCloudStoredConsent.values) {
      if (candidate.name == value['rule']) return candidate;
    }
    throw const FormatException('Unknown HYBRID consent rule');
  }

  Future<void> _writeRule(
    String owner,
    String provider,
    HybridDisclosureScope scope,
    HybridCloudStoredConsent rule,
  ) async {
    final key = _key(owner, provider, scope);
    final value = jsonEncode(<String, Object>{
      'version': 1,
      'ownerDigest': _digest(owner),
      'provider': provider,
      'origin': scope.origin.name,
      'sensitivity': scope.sensitivity.name,
      'rule': rule.name,
    });
    await _backend.write(key, value);
    if (await _backend.read(key) != value) {
      throw StateError('HYBRID consent preference write was not confirmed');
    }
  }

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static String _key(
    String owner, String provider, HybridDisclosureScope scope,
  ) {
    if (owner.trim().isEmpty || owner.trim() != owner ||
        owner.length > 256 ||
        !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$').hasMatch(provider)) {
      throw ArgumentError('Invalid HYBRID Cloud consent identity');
    }
    return _prefix + _digest(jsonEncode(<String>[
      owner, provider, scope.origin.name, scope.sensitivity.name,
    ]));
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final pending = _tail.then((_) => operation());
    _tail = pending.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return pending;
  }
}
