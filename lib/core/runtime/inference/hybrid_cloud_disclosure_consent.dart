import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal OS-protected data access contract. This PR is independent of the
/// experimental checkpoint branch #975; both use FlutterSecureStorage, not
/// plaintext preferences or another SQLite memory store.
abstract interface class HybridCloudConsentStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Uses the app's existing protected storage plugin; no custom plaintext DB.
final class FlutterSecureCloudConsentStorage
    implements HybridCloudConsentStorage {
  FlutterSecureCloudConsentStorage({FlutterSecureStorage? secureStorage})
      : _storage = secureStorage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}


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
    required this.accountId,
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
        accountId.trim().isEmpty ||
        accountId != accountId.trim() ||
        accountId.length > 256 ||
        accountId.codeUnits.any((unit) => unit < 32 || unit == 127) ||
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
  /// Stable credential/account identity from trusted account selection.
  /// Switching Cloud accounts requires fresh consent.
  final String accountId;
  final String purpose;
  final String outboundText;
  final List<HybridDisclosureSegment> segments;

  List<HybridDisclosureScope> get scopes =>
      segments.map((segment) => segment.scope).toSet().toList(growable: false);

  /// Binds a one-shot UI review to an exact outgoing prompt and destination.
  /// This digest is not a secret or a replacement for consent.
  String get contentFingerprint => sha256.convert(utf8.encode(jsonEncode(
        <String>[
          ownerId, sessionId, providerId, accountId, purpose, outboundText,
          for (final segment in segments)
            jsonEncode(<String>[
              segment.scope.origin.name,
              segment.scope.sensitivity.name,
              segment.text,
            ]),
        ],
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

/// One-use, exact-payload permission issued only by the consent manager.
///
/// This object is not a credential, does not permit arbitrary prompts, and
/// cannot be constructed by external Dart libraries. Its validity expires on
/// owner/session revocation, provider/account change or content alteration.
final class HybridCloudDispatchPermit {
  HybridCloudDispatchPermit._({
    required HybridCloudDisclosureConsent issuer,
    required HybridCloudDisclosure approved,
    required int revision,
  })  : _issuer = issuer,
        _approved = approved,
        _revision = revision;

  final HybridCloudDisclosureConsent _issuer;
  final HybridCloudDisclosure _approved;
  final int _revision;
  bool _used = false;

  String get fingerprint => _approved.contentFingerprint;
}

/// Allows the protected consent queue to be released as soon as the trusted
/// sender has STARTED, rather than blocking revocation for network latency.
final class _HybridCloudStartedRequest<T> {
  const _HybridCloudStartedRequest(this.result);
  final Future<T> result;
}

/// Opt-in, fail-closed consent contract for Cloud data disclosures.
///
/// Preferences are per owner, provider, account, origin and sensitivity, persisted in
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
    required HybridCloudConsentStorage backend,
    required Future<bool> Function(String ownerId, String sessionId)
        authorizeOwnerSession,
  })  : _backend = backend,
        _authorizeOwnerSession = authorizeOwnerSession;

  final HybridCloudConsentStorage _backend;
  final Future<bool> Function(String ownerId, String sessionId)
      _authorizeOwnerSession;
  // Shared single-isolate lock; FlutterSecureStorage still lacks a
  // cross-process compare-and-swap. Do not enable production Cloud here.
  static Future<void> _sharedTail = Future<void>.value();
  static final Map<String, int> _epochs = <String, int>{};

  // New account-scoped format refuses legacy provider-wide grants.
  static const String _prefix = 'hybrid_cloud_consent_v3_';

  /// The dialog intentionally runs OUTSIDE the protected-storage queue.
  /// Otherwise a settings revocation during a visible consent dialog could
  /// deadlock or be delayed until AFTER an outbound approval.
  Future<bool> authorize({
    required HybridCloudDisclosure disclosure,
    Future<Map<HybridDisclosureScope, HybridCloudConsentChoice>> Function(
      HybridCloudConsentReview review,
    )? requestConsent,
  }) async {
    final familyKey =
        _key(disclosure.ownerId, disclosure.providerId, disclosure.accountId);
    final revision = _epochs[familyKey] ?? 0;
    if (!await _authorizeOwnerSession(
      disclosure.ownerId, disclosure.sessionId,
    )) {
      return false;
    }

    // Read rules in storage order, but never hold this lock while awaiting
    // the user's decision. Null indicates a persistent deny on any segment.
    final unapproved = await _serialize<List<HybridDisclosureScope>?>(() async {
      final pending = <HybridDisclosureScope>[];
      for (final scope in disclosure.scopes) {
        final rule = await _readRule(
          disclosure.ownerId, disclosure.providerId, disclosure.accountId, scope,
        );
        if (rule == HybridCloudStoredConsent.neverShare) return null;
        if (rule != HybridCloudStoredConsent.allowAlways ||
            scope.sensitivity == HybridDisclosureSensitivity.unknown) {
          pending.add(scope);
        }
      }
      return pending;
    });
    if (unapproved == null || revision != (_epochs[familyKey] ?? 0)) return false;
    if (unapproved.isEmpty) {
      return await _authorizeOwnerSession(
        disclosure.ownerId, disclosure.sessionId,
      ) && revision == (_epochs[familyKey] ?? 0);
    }
    if (requestConsent == null) return false;

    final decisions = await requestConsent(HybridCloudConsentReview(
      disclosure: disclosure,
      needsConsent: List<HybridDisclosureScope>.unmodifiable(unapproved),
    ));
    if (revision != (_epochs[familyKey] ?? 0) ||
        !await _authorizeOwnerSession(
          disclosure.ownerId, disclosure.sessionId,
        )) {
      return false;
    }
    if (decisions.length != unapproved.length ||
        !unapproved.every(decisions.containsKey)) {
      return false;
    }
    // A review may have changed another category's rule while the dialog
    // was open. Never override a newly persisted "never share" rule.
    return _serialize(() async {
      if (revision != (_epochs[familyKey] ?? 0) ||
          !await _authorizeOwnerSession(
            disclosure.ownerId, disclosure.sessionId,
          )) {
        return false;
      }
      for (final scope in disclosure.scopes) {
        if (await _readRule(disclosure.ownerId, disclosure.providerId, disclosure.accountId, scope) ==
            HybridCloudStoredConsent.neverShare) {
          return false;
        }
      }
      // Compute one complete registry transition before persisting.
      final updates = <HybridDisclosureScope, HybridCloudStoredConsent?>{};
      var approved = true;
      for (final scope in unapproved) {
        switch (decisions[scope]!) {
          case HybridCloudConsentChoice.allowOnce:
            break;
          case HybridCloudConsentChoice.allowAlways:
            if (scope.sensitivity == HybridDisclosureSensitivity.unknown) {
              return false;
            }
            updates[scope] = HybridCloudStoredConsent.allowAlways;
          case HybridCloudConsentChoice.allowAndAskNextTime:
            updates[scope] = HybridCloudStoredConsent.askEveryTime;
          case HybridCloudConsentChoice.denyOnce:
            approved = false;
          case HybridCloudConsentChoice.neverShare:
            updates[scope] = HybridCloudStoredConsent.neverShare;
            approved = false;
        }
      }
      if (!approved) {
        // No new positive grants for a denied, unsent mixed request.
        updates.removeWhere((_, value) =>
            value != HybridCloudStoredConsent.neverShare);
      }
      if (updates.isNotEmpty) {
        await _writeRules(disclosure.ownerId, disclosure.providerId,
            disclosure.accountId, updates);
      }
      return approved && revision == (_epochs[familyKey] ?? 0);
    });
  }

  /// Obtain a dispatch permit for one exact, fully classified outbound
  /// payload. The UI may suspend; no network request is started here.
  ///
  /// Unlike a plain bool from [authorize], the permit can be consumed once
  /// only, and is invalidated by same-isolate settings revocation.
  Future<HybridCloudDispatchPermit?> authorizeForDispatch({
    required HybridCloudDisclosure disclosure,
    Future<Map<HybridDisclosureScope, HybridCloudConsentChoice>> Function(
      HybridCloudConsentReview review,
    )? requestConsent,
  }) async {
    final familyKey = _key(
      disclosure.ownerId, disclosure.providerId, disclosure.accountId,
    );
    final revision = _epochs[familyKey] ?? 0;
    final approved = await authorize(
      disclosure: disclosure,
      requestConsent: requestConsent,
    );
    if (!approved || revision != (_epochs[familyKey] ?? 0)) {
      return null;
    }
    return HybridCloudDispatchPermit._(
      issuer: this,
      approved: disclosure,
      revision: revision,
    );
  }

  /// FINAL opt-in check immediately before a trusted network sender starts.
  ///
  /// The sender receives ONLY the exact reviewed disclosure. Its adapter must
  /// construct the actual HTTP/provider request faithfully, including system
  /// instructions, chat history, RAG excerpts, tool results and attachments.
  /// Never pass a sender that silently adds context after this check.
  ///
  /// The destination callback must consult the CURRENT selected credential,
  /// not the label carried by the review. This API remains unconnected to
  /// production Chat/Cloud transport until a trusted assembler and authenticated
  /// provider/account selector exist.
  Future<T> dispatchApproved<T>({
    required HybridCloudDispatchPermit permit,
    required HybridCloudDisclosure currentDisclosure,
    required Future<bool> Function(String providerId, String accountId)
        isCurrentDestination,
    required Future<T> Function(HybridCloudDisclosure exactDisclosure)
        trustedSend,
  }) async {
    final started = await _serialize<_HybridCloudStartedRequest<T>>(() async {
      // Burn immediately, including on mismatch or provider failure.
      // A review can NEVER be replayed with a second provider request.
      if (permit._used) {
        throw StateError('HYBRID Cloud consent permit was already consumed');
      }
      permit._used = true;
      if (!identical(permit._issuer, this) ||
          permit._approved.contentFingerprint !=
              currentDisclosure.contentFingerprint) {
        throw StateError('HYBRID Cloud disclosure changed after consent');
      }

      final approved = permit._approved;
      final familyKey = _key(
        approved.ownerId, approved.providerId, approved.accountId,
      );
      if (permit._revision != (_epochs[familyKey] ?? 0)) {
        throw StateError('HYBRID Cloud consent revoked before dispatch');
      }
      if (!await _authorizeOwnerSession(
        approved.ownerId, approved.sessionId,
      )) {
        throw StateError('HYBRID owner/session revoked before dispatch');
      }
      if (!await isCurrentDestination(
        approved.providerId, approved.accountId,
      )) {
        throw StateError('HYBRID Cloud destination changed after consent');
      }
      // The callbacks may yield; check revocation AGAIN without yielding
      // between the final checks and invocation of the trusted sender.
      if (permit._revision != (_epochs[familyKey] ?? 0)) {
        throw StateError('HYBRID Cloud consent revoked before dispatch');
      }
      for (final scope in approved.scopes) {
        if (await _readRule(
          approved.ownerId, approved.providerId, approved.accountId, scope,
        ) == HybridCloudStoredConsent.neverShare) {
          throw StateError('HYBRID Cloud category is no longer shareable');
        }
      }
      if (permit._revision != (_epochs[familyKey] ?? 0)) {
        throw StateError('HYBRID Cloud consent revoked before dispatch');
      }

      // Start while holding the same-isolate consent queue; return a wrapper
      // rather than awaiting the network Future inside the queue.
      return _HybridCloudStartedRequest<T>(trustedSend(approved));
    });
    return started.result;
  }

  /// Used by a settings/consent-management UI. Explicit user action only.
  /// Revocation changes a remembered allow to no automatic consent.
  Future<void> revoke({
    required String ownerId,
    required String sessionId,
    required String providerId,
    required String accountId,
    required HybridDisclosureScope scope,
  }) {
    // Invalidate outstanding dialogs synchronously. No UI callback needs to
    // wait for the revocation's protected storage operation to complete.
    final familyKey = _key(ownerId, providerId, accountId);
    _epochs[familyKey] = (_epochs[familyKey] ?? 0) + 1;
    return _serialize(() async {
      if (!await _authorizeOwnerSession(ownerId, sessionId)) {
        throw StateError('HYBRID consent owner/session is not authorized');
      }
      await _writeRules(ownerId, providerId, accountId,
          <HybridDisclosureScope, HybridCloudStoredConsent?>{scope: null});
    });
  }

  Future<HybridCloudStoredConsent?> storedPreference({
    required String ownerId,
    required String sessionId,
    required String providerId,
    required String accountId,
    required HybridDisclosureScope scope,
  }) => _serialize(() async {
        if (!await _authorizeOwnerSession(ownerId, sessionId)) {
          throw StateError('HYBRID consent owner/session is not authorized');
        }
        return _readRule(ownerId, providerId, accountId, scope);
      });

  static String _scopeKey(HybridDisclosureScope scope) =>
      scope.origin.name + ':' + scope.sensitivity.name;

  Future<HybridCloudStoredConsent?> _readRule(
    String owner, String provider, String account,
    HybridDisclosureScope scope,
  ) async => (await _readRules(owner, provider, account))[_scopeKey(scope)];

  Future<Map<String, HybridCloudStoredConsent>> _readRules(
    String owner, String provider, String account,
  ) async {
    final raw = await _backend.read(_key(owner, provider, account));
    if (raw == null) return <String, HybridCloudStoredConsent>{};
    if (raw.length > 8192) {
      throw const FormatException('Oversized HYBRID consent registry');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['version'] != 3 ||
        decoded['ownerDigest'] != _digest(owner) ||
        decoded['provider'] != provider ||
        decoded['accountDigest'] != _digest(account) ||
        decoded['rules'] is! Map) {
      throw const FormatException('Invalid HYBRID consent registry');
    }
    final data = decoded['rules'] as Map;
    final legal = <String>{
      for (final origin in HybridDisclosureOrigin.values)
        for (final sensitivity in HybridDisclosureSensitivity.values)
          _scopeKey(HybridDisclosureScope(origin, sensitivity)),
    };
    if (data.length > legal.length) {
      throw const FormatException('Too many consent categories');
    }
    final parsed = <String, HybridCloudStoredConsent>{};
    for (final row in data.entries) {
      if (row.key is! String ||
          !legal.contains(row.key) ||
          row.value is! String) {
        throw const FormatException('Invalid consent category');
      }
      HybridCloudStoredConsent? rule;
      for (final candidate in HybridCloudStoredConsent.values) {
        if (candidate.name == row.value) rule = candidate;
      }
      if (rule == null) {
        throw const FormatException('Unknown consent rule');
      }
      parsed[row.key as String] = rule;
    }
    return parsed;
  }

  /// One OS-protected record/readback for all categories in the decision.
  /// In-process serialized; storage-level cross-process CAS still absent.
  Future<void> _writeRules(
    String owner, String provider, String account,
    Map<HybridDisclosureScope, HybridCloudStoredConsent?> changes,
  ) async {
    final key = _key(owner, provider, account);
    final rules = await _readRules(owner, provider, account);
    for (final item in changes.entries) {
      if (item.value == null) {
        rules.remove(_scopeKey(item.key));
      } else {
        rules[_scopeKey(item.key)] = item.value!;
      }
    }
    if (rules.isEmpty) {
      await _backend.delete(key);
      if (await _backend.read(key) != null) {
        throw StateError('HYBRID consent removal not confirmed');
      }
      return;
    }
    final encoded = jsonEncode(<String, Object>{
      'version': 3,
      'ownerDigest': _digest(owner),
      'provider': provider,
      'accountDigest': _digest(account),
      'rules': <String, String>{
        for (final entry in rules.entries) entry.key: entry.value.name,
      },
    });
    await _backend.write(key, encoded);
    if (await _backend.read(key) != encoded) {
      throw StateError('HYBRID consent registry write not confirmed');
    }
  }

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static String _key(String owner, String provider, String account) {
    if (owner.trim().isEmpty ||
        owner.trim() != owner || owner.length > 256 ||
        account.trim().isEmpty ||
        account.trim() != account || account.length > 256 ||
        account.codeUnits.any((unit) => unit < 32 || unit == 127) ||
        !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$')
            .hasMatch(provider)) {
      throw ArgumentError('Invalid HYBRID Cloud consent identity');
    }
    return _prefix + _digest(jsonEncode(<String>[owner, provider, account]));
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final pending = _sharedTail.then((_) => operation());
    _sharedTail =
        pending.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return pending;
  }
}
