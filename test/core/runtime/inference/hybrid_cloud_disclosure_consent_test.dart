import 'dart:async';

import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ProtectedBackend implements HybridCloudConsentStorage {
  final Map<String, String> values = <String, String>{};
  bool failWrite = false;
  bool hideReadback = false;
  int writeCount = 0;

  @override
  Future<String?> read(String key) async =>
      hideReadback ? null : values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('OS-protected write failed');
    writeCount++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  const owner = 'local-owner';
  const session = 'chat-a';
  const question = HybridDisclosureScope(
    HybridDisclosureOrigin.currentQuestion,
    HybridDisclosureSensitivity.personal,
  );
  const memory = HybridDisclosureScope(
    HybridDisclosureOrigin.durableMemory,
    HybridDisclosureSensitivity.personal,
  );
  const privateHistory = HybridDisclosureScope(
    HybridDisclosureOrigin.conversationHistory,
    HybridDisclosureSensitivity.highlySensitive,
  );
  const document = HybridDisclosureScope(
    HybridDisclosureOrigin.documentExcerpt,
    HybridDisclosureSensitivity.confidential,
  );
  const unknown = HybridDisclosureScope(
    HybridDisclosureOrigin.toolResult,
    HybridDisclosureSensitivity.unknown,
  );

  late _ProtectedBackend backend;
  late HybridCloudDisclosureConsent consent;
  var validSession = true;
  var accessChecks = 0;

  setUp(() {
    backend = _ProtectedBackend();
    validSession = true;
    accessChecks = 0;
    consent = HybridCloudDisclosureConsent(
      backend: backend,
      authorizeOwnerSession: (ownerId, sessionId) async {
        accessChecks++;
        return validSession && ownerId == owner && sessionId == session;
      },
    );
  });

  HybridCloudDisclosure disclosure({
    String provider = 'gemini',
    String account = 'primary-credential',
    String sessionId = session,
    List<HybridDisclosureSegment>? parts,
  }) {
    final segments = parts ?? const <HybridDisclosureSegment>[
      HybridDisclosureSegment(text: 'Current question.', scope: question),
      HybridDisclosureSegment(text: '\nMy private memory.', scope: memory),
    ];
    return HybridCloudDisclosure(
      ownerId: owner,
      sessionId: sessionId,
      providerId: provider,
      accountId: account,
      purpose: 'Give a more complete and personalized answer',
      outboundText: segments.map((item) => item.text).join(),
      segments: segments,
    );
  }

  Map<HybridDisclosureScope, HybridCloudConsentChoice> decideAll(
    HybridCloudConsentReview review,
    HybridCloudConsentChoice decision,
  ) => <HybridDisclosureScope, HybridCloudConsentChoice>{
    for (final scope in review.needsConsent) scope: decision,
  };

  test('no consent UI or stored permission = no Cloud disclosure', () async {
    final outbound = disclosure();
    expect(await consent.authorize(disclosure: outbound), isFalse);
    expect(backend.values, isEmpty);
    expect(accessChecks, 1);
  });

  test('exact outbound payload MUST be completely classified', () {
    expect(
      () => HybridCloudDisclosure(
        ownerId: owner,
        sessionId: session,
        providerId: 'gemini', accountId: 'primary-credential',
        purpose: 'Reply',
        outboundText: 'Question + undisclosed history',
        segments: const <HybridDisclosureSegment>[
          HybridDisclosureSegment(text: 'Question', scope: question),
        ],
      ),
      throwsArgumentError,
    );
    expect(() => disclosure(provider: 'provider|spoof'), throwsArgumentError);
  });

  test('one-shot approval is for this request only, not a category grant',
      () async {
    final outbound = disclosure();
    var asks = 0;
    Future<Map<HybridDisclosureScope, HybridCloudConsentChoice>> review(
        HybridCloudConsentReview r) async {
      asks++;
      expect(r.disclosure.providerId, 'gemini');
      expect(r.disclosure.outboundText, outbound.outboundText);
      expect(r.fingerprint, outbound.contentFingerprint);
      expect(r.needsConsent, containsAll(<HybridDisclosureScope>[
        question, memory,
      ]));
      return decideAll(r, HybridCloudConsentChoice.allowOnce);
    }

    expect(await consent.authorize(
      disclosure: outbound, requestConsent: review,
    ), isTrue);
    expect(await consent.authorize(
      disclosure: outbound, requestConsent: review,
    ), isTrue);
    expect(asks, 2);
    expect(backend.values, isEmpty);
  });

  test('automatic consent is scoped to provider, source and sensitivity',
      () async {
    var asks = 0;
    Future<Map<HybridDisclosureScope, HybridCloudConsentChoice>> approve(
        HybridCloudConsentReview review) async {
      asks++;
      return decideAll(review, HybridCloudConsentChoice.allowAlways);
    }
    expect(await consent.authorize(
      disclosure: disclosure(), requestConsent: approve,
    ), isTrue);
    expect(asks, 1);
    expect(backend.values, hasLength(1));
    // Different text of the SAME explicitly allowed categories can proceed.
    expect(await consent.authorize(
      disclosure: disclosure(parts: const <HybridDisclosureSegment>[
        HybridDisclosureSegment(text: 'New private question', scope: question),
        HybridDisclosureSegment(text: 'New remembered fact', scope: memory),
      ]),
    ), isTrue);
    expect(asks, 1);

    // The same categories at a different provider are NOT automatically
    // authorized, even when the user is already in Hybrid/Cloud mode.
    expect(await consent.authorize(
      disclosure: disclosure(provider: 'openai'),
    ), isFalse);
    expect(await consent.authorize(
      disclosure: disclosure(provider: 'openai'), requestConsent: approve,
    ), isTrue);
    expect(asks, 2);

    // An authorized memory class never silently authorizes chat history.
    expect(await consent.authorize(
      disclosure: disclosure(parts: const <HybridDisclosureSegment>[
        HybridDisclosureSegment(text: 'Selected history', scope: privateHistory),
      ]),
    ), isFalse);
  });

  test('account switch requires fresh consent for the same provider',
      () async {
    final primary = disclosure();
    final secondary = disclosure(account: 'other-credential');
    expect(primary.contentFingerprint, isNot(secondary.contentFingerprint));
    expect(await consent.authorize(
      disclosure: primary,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowAlways),
    ), isTrue);
    expect(await consent.authorize(disclosure: primary), isTrue);
    expect(await consent.authorize(disclosure: secondary), isFalse);
    expect(await consent.authorize(
      disclosure: secondary,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowOnce),
    ), isTrue);
    expect(await consent.authorize(disclosure: secondary), isFalse);
    expect(backend.values.values.join(), isNot(contains('primary-credential')));
    expect(backend.values.values.join(), isNot(contains('other-credential')));
  });

  test('mixed denial does not persist automatic grants for unsent sections',
      () async {
    expect(await consent.authorize(
      disclosure: disclosure(),
      requestConsent: (_) async => <HybridDisclosureScope, HybridCloudConsentChoice>{
        question: HybridCloudConsentChoice.allowAlways,
        memory: HybridCloudConsentChoice.denyOnce,
      },
    ), isFalse);
    expect(backend.values, isEmpty);
  });

  test('mixed permanent denial persists only forbidden scope', () async {
    expect(await consent.authorize(
      disclosure: disclosure(),
      requestConsent: (_) async => <HybridDisclosureScope, HybridCloudConsentChoice>{
        question: HybridCloudConsentChoice.allowAlways,
        memory: HybridCloudConsentChoice.neverShare,
      },
    ), isFalse);
    expect(backend.values, hasLength(1));
    expect(await consent.storedPreference(
      ownerId: owner, sessionId: session,
      providerId: 'gemini', accountId: 'primary-credential', scope: question,
    ), isNull);
    expect(await consent.storedPreference(
      ownerId: owner, sessionId: session,
      providerId: 'gemini', accountId: 'primary-credential', scope: memory,
    ), HybridCloudStoredConsent.neverShare);
  });

  test('ask on every use is remembered but never authorizes silently',
      () async {
    final outbound = disclosure(parts: const <HybridDisclosureSegment>[
      HybridDisclosureSegment(text: 'Personal memory', scope: memory),
    ]);
    var asks = 0;
    Future<Map<HybridDisclosureScope, HybridCloudConsentChoice>> approve(
        HybridCloudConsentReview review) async {
      asks++;
      return decideAll(review, HybridCloudConsentChoice.allowAndAskNextTime);
    }
    expect(await consent.authorize(
      disclosure: outbound, requestConsent: approve,
    ), isTrue);
    expect(await consent.storedPreference(
      ownerId: owner, sessionId: session, providerId: 'gemini', accountId: 'primary-credential',
      scope: memory,
    ), HybridCloudStoredConsent.askEveryTime);
    expect(await consent.authorize(disclosure: outbound), isFalse);
    expect(await consent.authorize(
      disclosure: outbound, requestConsent: approve,
    ), isTrue);
    expect(asks, 2);
  });

  test('deny once and persistent never share have distinct semantics',
      () async {
    final outbound = disclosure(parts: const <HybridDisclosureSegment>[
      HybridDisclosureSegment(text: 'Sensitive history', scope: privateHistory),
    ]);
    expect(await consent.authorize(
      disclosure: outbound,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.denyOnce),
    ), isFalse);
    expect(backend.values, isEmpty);
    expect(await consent.authorize(
      disclosure: outbound,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.neverShare),
    ), isFalse);
    expect(await consent.storedPreference(
      ownerId: owner, sessionId: session, providerId: 'gemini', accountId: 'primary-credential',
      scope: privateHistory,
    ), HybridCloudStoredConsent.neverShare);
    var laterPromptCalled = false;
    expect(await consent.authorize(
      disclosure: outbound,
      requestConsent: (_) async {
        laterPromptCalled = true;
        return const <HybridDisclosureScope, HybridCloudConsentChoice>{};
      },
    ), isFalse);
    expect(laterPromptCalled, isFalse);

    await consent.revoke(
      ownerId: owner, sessionId: session, providerId: 'gemini', accountId: 'primary-credential',
      scope: privateHistory,
    );
    expect(await consent.authorize(
      disclosure: outbound,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowOnce),
    ), isTrue);
    expect(backend.values, isEmpty);
  });

  test('two allowed categories persist in exactly one protected write',
      () async {
    final before = backend.writeCount;
    expect(await consent.authorize(
      disclosure: disclosure(),
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowAlways),
    ), isTrue);
    expect(backend.writeCount - before, 1);
    expect(backend.values, hasLength(1));
    expect(await consent.storedPreference(
      ownerId: owner, sessionId: session,
      providerId: 'gemini', accountId: 'primary-credential',
      scope: memory,
    ), HybridCloudStoredConsent.allowAlways);
  });

  test('revocation by another instance invalidates an open review', () async {
    final other = HybridCloudDisclosureConsent(
      backend: backend,
      authorizeOwnerSession: (ownerId, sessionId) async =>
          ownerId == owner && sessionId == session,
    );
    final entered = Completer<void>();
    final finished = Completer<void>();
    final result = consent.authorize(
      disclosure: disclosure(),
      requestConsent: (r) async {
        entered.complete();
        await finished.future;
        return decideAll(r, HybridCloudConsentChoice.allowAlways);
      },
    );
    await entered.future;
    await other.revoke(
      ownerId: owner, sessionId: session,
      providerId: 'gemini', accountId: 'primary-credential',
      scope: memory,
    );
    finished.complete();
    expect(await result, isFalse);
    expect(backend.values, isEmpty);
  });

  test('cross-instance category revocation does not erase other grants',
      () async {
    final other = HybridCloudDisclosureConsent(
      backend: backend,
      authorizeOwnerSession: (ownerId, sessionId) async =>
          ownerId == owner && sessionId == session,
    );
    expect(await other.authorize(
      disclosure: disclosure(),
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowAlways),
    ), isTrue);
    await consent.revoke(
      ownerId: owner, sessionId: session,
      providerId: 'gemini', accountId: 'primary-credential', scope: memory,
    );
    expect(await other.authorize(disclosure: disclosure()), isFalse);
    expect(await other.storedPreference(
      ownerId: owner, sessionId: session,
      providerId: 'gemini', accountId: 'primary-credential', scope: question,
    ), HybridCloudStoredConsent.allowAlways);
  });

  test('changed sensitivity of the same outbound text changes fingerprint',
      () {
    final a = disclosure(parts: const <HybridDisclosureSegment>[
      HybridDisclosureSegment(text: 'same', scope: memory),
    ]);
    final b = disclosure(parts: const <HybridDisclosureSegment>[
      HybridDisclosureSegment(text: 'same', scope: question),
    ]);
    expect(a.outboundText, b.outboundText);
    expect(a.contentFingerprint, isNot(b.contentFingerprint));
  });

  test('revoking during an open dialog invalidates consent without deadlock',
      () async {
    final outbound = disclosure(parts: const <HybridDisclosureSegment>[
      HybridDisclosureSegment(text: 'Private memory', scope: memory),
    ]);
    final entered = Completer<void>();
    final finishReview = Completer<void>();
    final pending = consent.authorize(
      disclosure: outbound,
      requestConsent: (r) async {
        entered.complete();
        await finishReview.future;
        return decideAll(r, HybridCloudConsentChoice.allowAlways);
      },
    );
    await entered.future;
    // Unlike a storage queue held during the dialog, this completes even
    // while the user's consent callback is still suspended.
    await consent.revoke(
      ownerId: owner, sessionId: session,
      providerId: 'gemini', accountId: 'primary-credential', scope: memory,
    );
    finishReview.complete();
    expect(await pending, isFalse);
    expect(await consent.storedPreference(
      ownerId: owner, sessionId: session,
      providerId: 'gemini', accountId: 'primary-credential', scope: memory,
    ), isNull);
  });

  test('revoke persistent allow; next Cloud use must request consent',
      () async {
    final outbound = disclosure(parts: const <HybridDisclosureSegment>[
      HybridDisclosureSegment(text: 'Confidential document', scope: document),
    ]);
    expect(await consent.authorize(
      disclosure: outbound,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowAlways),
    ), isTrue);
    expect(await consent.authorize(disclosure: outbound), isTrue);
    await consent.revoke(
      ownerId: owner, sessionId: session,
      providerId: 'gemini', accountId: 'primary-credential', scope: document,
    );
    expect(await consent.storedPreference(
      ownerId: owner, sessionId: session,
      providerId: 'gemini', accountId: 'primary-credential', scope: document,
    ), isNull);
    expect(await consent.authorize(disclosure: outbound), isFalse);
  });

  test('all classes in a mixed payload must receive complete decisions',
      () async {
    final outbound = disclosure(parts: const <HybridDisclosureSegment>[
      HybridDisclosureSegment(text: 'memory', scope: memory),
      HybridDisclosureSegment(text: 'secret', scope: privateHistory),
      HybridDisclosureSegment(text: 'doc', scope: document),
    ]);
    expect(await consent.authorize(
      disclosure: outbound,
      requestConsent: (_) async =>
          <HybridDisclosureScope, HybridCloudConsentChoice>{
            memory: HybridCloudConsentChoice.allowOnce,
            document: HybridCloudConsentChoice.allowOnce,
          },
    ), isFalse);
    expect(backend.values, isEmpty);
    expect(await consent.authorize(
      disclosure: outbound,
      requestConsent: (r) async => <HybridDisclosureScope, HybridCloudConsentChoice>{
        for (final scope in r.needsConsent)
          scope: scope == privateHistory
              ? HybridCloudConsentChoice.denyOnce
              : HybridCloudConsentChoice.allowOnce,
      },
    ), isFalse);
    // The caller must construct a different outgoing payload without the
    // denied segment, then obtain consent for exactly that text.
    final reduced = disclosure(parts: const <HybridDisclosureSegment>[
      HybridDisclosureSegment(text: 'memory', scope: memory),
      HybridDisclosureSegment(text: 'doc', scope: document),
    ]);
    expect(await consent.authorize(
      disclosure: reduced,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowOnce),
    ), isTrue);
  });

  test('unknown sensitivity cannot be permanently auto-approved', () async {
    final outbound = disclosure(parts: const <HybridDisclosureSegment>[
      HybridDisclosureSegment(text: 'Unclassified content', scope: unknown),
    ]);
    expect(await consent.authorize(
      disclosure: outbound,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowAlways),
    ), isFalse);
    expect(backend.values, isEmpty);
    expect(await consent.authorize(
      disclosure: outbound,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowOnce),
    ), isTrue);
    expect(await consent.authorize(disclosure: outbound), isFalse);
  });

  test('invalid owner and session revoke during dialog block disclosure',
      () async {
    final outbound = disclosure();
    validSession = false;
    expect(await consent.authorize(
      disclosure: outbound,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowAlways),
    ), isFalse);
    expect(backend.values, isEmpty);
    validSession = true;
    expect(await consent.authorize(
      disclosure: outbound,
      requestConsent: (r) async {
        validSession = false; // Logout during review.
        return decideAll(r, HybridCloudConsentChoice.allowAlways);
      },
    ), isFalse);
    expect(backend.values, isEmpty);
  });

  test('protected write failure or unconfirmed readback prevents opt-in',
      () async {
    final outbound = disclosure();
    backend.failWrite = true;
    await expectLater(consent.authorize(
      disclosure: outbound,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowAlways),
    ), throwsStateError);
    expect(backend.values, isEmpty);
    backend.failWrite = false;
    backend.hideReadback = true;
    await expectLater(consent.authorize(
      disclosure: outbound,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowAlways),
    ), throwsStateError);
    expect(backend.values, isNotEmpty);
  });

  test('tampered protected preference cannot authorize a Cloud send',
      () async {
    final outbound = disclosure(parts: const <HybridDisclosureSegment>[
      HybridDisclosureSegment(text: 'Private memory', scope: memory),
    ]);
    expect(await consent.authorize(
      disclosure: outbound,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowAlways),
    ), isTrue);
    final key = backend.values.keys.single;
    backend.values[key] = '{"version":1,"rule":"allowAlways","provider":"spoof"}';
    await expectLater(consent.authorize(disclosure: outbound),
        throwsFormatException);
  });

  test('dispatch permit starts one exact authorized Cloud request once',
      () async {
    final disclosureValue = disclosure();
    final permit = await consent.authorizeForDispatch(
      disclosure: disclosureValue,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowOnce),
    );
    expect(permit, isNotNull);
    expect(permit!.fingerprint, disclosureValue.contentFingerprint);
    var calls = 0;
    final answer = await consent.dispatchApproved<String>(
      permit: permit,
      currentDisclosure: disclosureValue,
      isCurrentDestination: (provider, account) async =>
          provider == 'gemini' && account == 'primary-credential',
      trustedSend: (exact) async {
        calls++;
        expect(exact.outboundText, disclosureValue.outboundText);
        return 'model-response';
      },
    );
    expect(answer, 'model-response');
    expect(calls, 1);
    await expectLater(
      consent.dispatchApproved<String>(
        permit: permit,
        currentDisclosure: disclosureValue,
        isCurrentDestination: (_, __) async => true,
        trustedSend: (_) async {
          calls++;
          return 'duplicate';
        },
      ),
      throwsStateError,
    );
    expect(calls, 1);
    expect(backend.values, isEmpty); // One-shot never becomes permanent.
  });

  test('modified prompt or classification cannot reuse a review',
      () async {
    final original = disclosure();
    final permit = (await consent.authorizeForDispatch(
      disclosure: original,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowOnce),
    ))!;
    var calls = 0;
    await expectLater(
      consent.dispatchApproved<String>(
        permit: permit,
        currentDisclosure: disclosure(parts: const <HybridDisclosureSegment>[
          HybridDisclosureSegment(
            text: 'A different prompt', scope: question,
          ),
        ]),
        isCurrentDestination: (_, __) async => true,
        trustedSend: (_) async {
          calls++;
          return 'must-not-run';
        },
      ),
      throwsStateError,
    );
    expect(calls, 0);
    final newPermit = (await consent.authorizeForDispatch(
      disclosure: original,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowOnce),
    ))!;
    await expectLater(
      consent.dispatchApproved<String>(
        permit: newPermit,
        currentDisclosure: disclosure(parts: <HybridDisclosureSegment>[
          HybridDisclosureSegment(
            text: original.outboundText, scope: privateHistory,
          ),
        ]),
        isCurrentDestination: (_, __) async => true,
        trustedSend: (_) async {
          calls++;
          return 'must-not-run';
        },
      ),
      throwsStateError,
    );
    expect(calls, 0);
  });

  test('provider or account switch after approval blocks network dispatch',
      () async {
    final original = disclosure();
    final permit = (await consent.authorizeForDispatch(
      disclosure: original,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowOnce),
    ))!;
    var calls = 0;
    await expectLater(
      consent.dispatchApproved<String>(
        permit: permit,
        currentDisclosure: original,
        isCurrentDestination: (provider, account) async =>
            provider == 'openai' || account == 'other-credential',
        trustedSend: (_) async {
          calls++;
          return 'must-not-run';
        },
      ),
      throwsStateError,
    );
    expect(calls, 0);
  });

  test('revocation after approval invalidates a not-yet-used permit',
      () async {
    final original = disclosure();
    final permit = (await consent.authorizeForDispatch(
      disclosure: original,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowOnce),
    ))!;
    await consent.revoke(
      ownerId: owner, sessionId: session,
      providerId: 'gemini', accountId: 'primary-credential', scope: memory,
    );
    var calls = 0;
    await expectLater(
      consent.dispatchApproved<String>(
        permit: permit,
        currentDisclosure: original,
        isCurrentDestination: (_, __) async => true,
        trustedSend: (_) async {
          calls++;
          return 'must-not-run';
        },
      ),
      throwsStateError,
    );
    expect(calls, 0);
  });

  test('session revoked after review prevents final provider call',
      () async {
    final original = disclosure();
    final permit = (await consent.authorizeForDispatch(
      disclosure: original,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowOnce),
    ))!;
    validSession = false;
    var calls = 0;
    await expectLater(
      consent.dispatchApproved<String>(
        permit: permit,
        currentDisclosure: original,
        isCurrentDestination: (_, __) async => true,
        trustedSend: (_) async {
          calls++;
          return 'must-not-run';
        },
      ),
      throwsStateError,
    );
    expect(calls, 0);
  });

  test('rejected review does not issue a Cloud dispatch permit', () async {
    final permit = await consent.authorizeForDispatch(
      disclosure: disclosure(),
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.denyOnce),
    );
    expect(permit, isNull);
  });

  test('stored rules contain no actual personal prompt or memory text',
      () async {
    final outbound = disclosure();
    expect(await consent.authorize(
      disclosure: outbound,
      requestConsent: (r) async =>
          decideAll(r, HybridCloudConsentChoice.allowAlways),
    ), isTrue);
    final stored = backend.values.values.join('\n');
    expect(stored, isNot(contains('My private memory.')));
    expect(stored, isNot(contains('Current question.')));
    expect(stored, isNot(contains('Give a more complete')));
  });
}
