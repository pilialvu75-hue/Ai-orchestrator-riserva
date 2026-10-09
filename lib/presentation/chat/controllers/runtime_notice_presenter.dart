import 'dart:async';

import 'package:flutter/material.dart';

/// A runtime notice is a state transition, not a notification per token.
/// Keep its lifetime bounded even when an action/accessibility keeps a snackbar
/// open. New runtime notices replace transient notifications instead of queuing.
class RuntimeNoticePresenter {
  String? _lastMessage;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _active;
  Timer? _expiry;

  void update(
    BuildContext context,
    String? message, {
    SnackBarAction? action,
  }) {
    final normalized = message?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (next == _lastMessage) return;
    _lastMessage = next;
    _expiry?.cancel();
    _active?.close();
    _active = null;
    if (next == null) return;

    final messenger = ScaffoldMessenger.of(context);
    // A queued snackbar cannot be closed through its controller until visible.
    // Runtime feedback supersedes old transient notifications on this screen.
    messenger.clearSnackBars();
    messenger.removeCurrentSnackBar();
    final controller = messenger.showSnackBar(
      SnackBar(
        content: Text(next, maxLines: 3, overflow: TextOverflow.ellipsis),
        backgroundColor: Theme.of(context).colorScheme.error,
        showCloseIcon: true,
        duration: const Duration(seconds: 6),
        action: action,
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
    _expiry = Timer(const Duration(seconds: 6), controller.close);
  }

  void dispose() {
    _expiry?.cancel();
    // Scaffold disposal owns removal; avoid ancestor lookups during teardown.
    _active = null;
  }
}
