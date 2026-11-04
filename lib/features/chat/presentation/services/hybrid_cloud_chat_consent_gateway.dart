import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:ai_orchestrator/features/settings/presentation/widgets/hybrid_cloud_consent_review_dialog.dart';
import 'package:flutter/material.dart';

typedef HybridCloudChatConsentChoices =
    Map<HybridDisclosureScope, HybridCloudConsentChoice>;

/// Presentation-side bridge to the existing translated Cloud review dialog.
///
/// A review belongs to the *visible chat session*, NOT to the unrelated,
/// device-local identity session used by the consent storage. The bridge
/// never authorizes a request: it only returns user choices to the protected
/// consent manager. Missing UI, closed Chat, inactive send and overlapping
/// dialogs all fail closed. No Cloud transport is registered here.
///
/// Source-only milestone: the production CloudRuntimeProvider has not been
/// switched to the opt-in consent-gated transport.
final class HybridCloudChatConsentGateway {
  HybridCloudChatConsentGateway._();

  static final HybridCloudChatConsentGateway instance =
      HybridCloudChatConsentGateway._();

  _ChatConsentHost? _host;
  _PendingCloudReview? _pending;
  int _revision = 0;

  /// Register the ChatPage whose BuildContext owns the visible navigation.
  ///
  /// The returned identity token must be used to detach. A stale Chat page
  /// cannot detach a newer page that took over the active UI.
  Object bind({
    required BuildContext context,
    required String Function() activeSessionId,
    required bool Function() isSending,
  }) {
    invalidate();
    final host = _ChatConsentHost(
      context: context,
      activeSessionId: activeSessionId,
      isSending: isSending,
    );
    _host = host;
    return host;
  }

  void unbind(Object identity) {
    if (identical(_host, identity)) {
      _host = null;
      invalidate();
    }
  }

  /// Called on navigation, session restoration and cancellation. It revokes
  /// any pending UI response and removes ONLY the exact Cloud review route,
  /// never an unrelated modal, drawer or page. The manager still performs its
  /// own one-use permission and cancellation-token verification.
  void invalidate() {
    _revision++;
    final pending = _pending;
    _pending = null;
    if (pending == null) return;
    if (pending.navigator.mounted && pending.route.isActive) {
      pending.navigator.removeRoute(pending.route);
    }
  }

  Future<HybridCloudChatConsentChoices> ask({
    required String chatSessionId,
    required HybridCloudConsentReview review,
    required bool Function() isRequestActive,
  }) async {
    final host = _host;
    if (host == null || _pending != null || !_valid(
      host, chatSessionId, isRequestActive,
    )) {
      return <HybridDisclosureScope, HybridCloudConsentChoice>{};
    }
    final navigator = Navigator.maybeOf(host.context, rootNavigator: true);
    if (navigator == null || !navigator.mounted) {
      return <HybridDisclosureScope, HybridCloudConsentChoice>{};
    }
    final revision = _revision;
    final route = DialogRoute<HybridCloudChatConsentChoices>(
      context: host.context,
      barrierDismissible: true,
      builder: (_) => HybridCloudConsentReviewDialog(review: review),
    );
    final pending = _PendingCloudReview(navigator, route);
    _pending = pending;
    try {
      final result = await navigator.push(route);
      if (_revision != revision ||
          !identical(_host, host) ||
          !identical(_pending, pending) ||
          !_valid(host, chatSessionId, isRequestActive)) {
        return <HybridDisclosureScope, HybridCloudConsentChoice>{};
      }
      return result == null
          ? <HybridDisclosureScope, HybridCloudConsentChoice>{}
          : Map<HybridDisclosureScope, HybridCloudConsentChoice>.unmodifiable(
              result,
            );
    } catch (_) {
      // Disposed navigation and UI errors cannot become an approval.
      return <HybridDisclosureScope, HybridCloudConsentChoice>{};
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  bool _valid(
    _ChatConsentHost host,
    String sessionId,
    bool Function() isRequestActive,
  ) {
    if (!host.context.mounted || sessionId.trim().isEmpty) return false;
    try {
      return host.activeSessionId() == sessionId &&
          host.isSending() &&
          isRequestActive();
    } catch (_) {
      return false;
    }
  }
}

final class _ChatConsentHost {
  const _ChatConsentHost({
    required this.context,
    required this.activeSessionId,
    required this.isSending,
  });

  final BuildContext context;
  final String Function() activeSessionId;
  final bool Function() isSending;
}

final class _PendingCloudReview {
  const _PendingCloudReview(this.navigator, this.route);

  final NavigatorState navigator;
  final DialogRoute<HybridCloudChatConsentChoices> route;
}
