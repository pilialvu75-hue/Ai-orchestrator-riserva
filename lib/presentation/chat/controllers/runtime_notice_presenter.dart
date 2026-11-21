import 'dart:async';

import 'package:flutter/material.dart';

/// A runtime notice is a state transition, not a notification per token.
/// Keep its lifetime bounded even when an action/accessibility keeps a snackbar
/// open. New runtime notices replace transient notifications instead of queuing.
class RuntimeNoticePresenter {
  String? _lastMessage;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _active;
  Timer? _expiry;

  void update(BuildContext context, String? message, {SnackBarAction? action}) {
    final normalized = message?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (next == _lastMessage) return;
    _lastMessage = next;
    _expiry?.cancel();
    _active?.close();
    _active = null;
    if (next == null) return;

    final isHybridTransition = next.startsWith('hybrid_fallback:');
    final language = Localizations.localeOf(context).languageCode;
    final transitionMessage = switch (next) {
      'hybrid_fallback:network_lost' => switch (language) {
        'fr' => 'Réseau perdu · passage en LOCAL',
        'en' => 'Network lost · switching to LOCAL',
        'es' => 'Red perdida · cambiando a LOCAL',
        _ => 'Rete persa · passaggio a LOCAL',
      },
      'hybrid_fallback:provider_unavailable' => switch (language) {
        'fr' => 'Fournisseur indisponible · passage en LOCAL',
        'en' => 'Provider unavailable · switching to LOCAL',
        'es' => 'Proveedor no disponible · cambiando a LOCAL',
        _ => 'Provider non disponibile · passaggio a LOCAL',
      },
      _ => next,
    };
    final lifetime = Duration(seconds: isHybridTransition ? 3 : 6);
    final messenger = ScaffoldMessenger.of(context);
    // A queued snackbar cannot be closed through its controller until visible.
    // Runtime feedback supersedes old transient notifications on this screen.
    messenger.clearSnackBars();
    messenger.removeCurrentSnackBar();
    final controller = messenger.showSnackBar(
      SnackBar(
        content: Text(transitionMessage,
            maxLines: isHybridTransition ? 2 : 3,
            overflow: TextOverflow.ellipsis),
        backgroundColor: isHybridTransition
            ? Theme.of(context).colorScheme.surfaceContainerHighest
            : Theme.of(context).colorScheme.error,
        behavior: isHybridTransition
            ? SnackBarBehavior.floating
            : SnackBarBehavior.fixed,
        margin: isHybridTransition
            ? const EdgeInsets.fromLTRB(16, 0, 16, 112)
            : null,
        showCloseIcon: !isHybridTransition,
        duration: lifetime,
        action: isHybridTransition ? null : action,
      ),
    );
    _active = controller;
    controller.closed.then((_) {
      if (identical(_active, controller)) {
        _active = null;
        _expiry?.cancel();
      }
    });
    // Bound the lifetime even if SnackBarAction keeps the notice persistent.
    _expiry = Timer(lifetime, controller.close);
  }

  void dispose() {
    _expiry?.cancel();
    // Scaffold disposal owns removal; avoid ancestor lookups during teardown.
    _active = null;
  }
}
