// AppLegalCore — Top-level initializer / gate widget.
//
// Drop [AppLegalInitializer] as the [home] of your [MaterialApp] (or wrap
// your existing home widget with it) and it will:
//
//   1. Call [EulaService.initialize()] during its own async init.
//   2. If no EULA acceptance is required → render [child] directly.
//   3. If EULA acceptance IS required   → show [EulaPage].
//   4. If the user declines             → show [LegalBlockedPage].
//
// Because the check happens asynchronously a brief transparent loading state
// is shown while the persisted preference is being read; this is invisible in
// practice (SharedPreferences read is sub-millisecond).
//
// Architecture notes
// ──────────────────
// • The widget is purely presentation-level.  All business logic lives in
//   [EulaService]; this widget just reacts to its output.
// • Compatible with AI-Orchestrator-Core and future AppHealthCore modules
//   because it wraps rather than replaces the host widget tree.

import 'package:flutter/material.dart';

import 'package:ai_orchestrator/core/app_legal/services/eula_service.dart';
import 'package:ai_orchestrator/core/app_legal/ui/eula_page.dart';
import 'package:ai_orchestrator/core/app_legal/ui/legal_blocked_page.dart';

enum _LegalGateStatus { loading, eulaRequired, declined, clear }

class AppLegalInitializer extends StatefulWidget {
  const AppLegalInitializer({
    super.key,
    required this.eulaService,
    required this.child,
  });

  final EulaService eulaService;

  /// The widget to show once the user has accepted the EULA.
  final Widget child;

  @override
  State<AppLegalInitializer> createState() => _AppLegalInitializerState();
}

class _AppLegalInitializerState extends State<AppLegalInitializer> {
  _LegalGateStatus _status = _LegalGateStatus.loading;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await widget.eulaService.initialize();
    if (!mounted) return;
    setState(() {
      _status = widget.eulaService.eulaRequired
          ? _LegalGateStatus.eulaRequired
          : _LegalGateStatus.clear;
    });
  }

  void _onAccepted() {
    if (!mounted) return;
    setState(() => _status = _LegalGateStatus.clear);
  }

  void _onDeclined() {
    if (!mounted) return;
    setState(() => _status = _LegalGateStatus.declined);
  }

  void _onReviewAgreement() {
    if (!mounted) return;
    setState(() => _status = _LegalGateStatus.eulaRequired);
  }

  @override
  Widget build(BuildContext context) {
    return switch (_status) {
      _LegalGateStatus.loading => const _LoadingGate(),
      _LegalGateStatus.eulaRequired => EulaPage(
          eulaService: widget.eulaService,
          onAccepted: _onAccepted,
          onDeclined: _onDeclined,
        ),
      _LegalGateStatus.declined => LegalBlockedPage(
          onReviewAgreement: _onReviewAgreement,
        ),
      _LegalGateStatus.clear => widget.child,
    };
  }
}

/// Invisible placeholder shown for the few milliseconds while preferences load.
class _LoadingGate extends StatelessWidget {
  const _LoadingGate();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0D0D0D),
      body: SizedBox.expand(),
    );
  }
}
