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

    final messenger = ScaffoldMessenger.of(context);
    // A queued snackbar cannot be closed through its controller until visible.
    // Runtime feedback supersedes old transient notifications on this screen.
    messenger.clearSnackBars();
    messenger.removeCurrentSnackBar();
    final controller = messenger.showSnackBar(
      SnackBar(
        content: Text(next, maxLines: 3, overflow: TextOverflow.ellipsis),
        // Floating snackbars anchor above Scaffold.bottomNavigationBar rather
        // than covering the chat composer on Windows and mobile.
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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


/// In-flow runtime feedback: never paints over the chat input or queues overlays.
class InlineRuntimeNotice extends StatefulWidget {
  const InlineRuntimeNotice({
    super.key,
    required this.message,
    this.settingsLabel,
    this.onSettings,
  });

  final String? message;
  final String? settingsLabel;
  final VoidCallback? onSettings;

  @override
  State<InlineRuntimeNotice> createState() => _InlineRuntimeNoticeState();
}

class _InlineRuntimeNoticeState extends State<InlineRuntimeNotice> {
  Timer? _timer;
  String? _message;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant InlineRuntimeNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final trimmed = widget.message?.trim();
    final next = trimmed == null || trimmed.isEmpty ? null : trimmed;
    if (next == _message) return;
    _timer?.cancel();
    _message = next;
    _visible = next != null;
    if (_visible) {
      _timer = Timer(const Duration(seconds: 6), _dismiss);
    }
  }

  void _dismiss() {
    _timer?.cancel();
    if (mounted && _visible) setState(() => _visible = false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const Key('inline-runtime-notice'),
      color: colors.errorContainer,
      child: Row(
        children: [
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                _message!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
          ),
          if (widget.onSettings != null)
            IconButton(
              tooltip: widget.settingsLabel,
              color: colors.onErrorContainer,
              onPressed: () {
                _dismiss();
                widget.onSettings?.call();
              },
              icon: const Icon(Icons.settings),
            ),
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            color: colors.onErrorContainer,
            onPressed: _dismiss,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}
