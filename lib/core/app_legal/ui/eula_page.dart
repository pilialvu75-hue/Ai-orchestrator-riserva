// AppLegalCore — Full-screen EULA acceptance page.
//
// Shown on every first launch and whenever a new EULA version is published.
// The Accept button is intentionally disabled until the user checks the
// confirmation checkbox, making accidental acceptance impossible.
//
// On accept  → calls [EulaService.acceptEula] then invokes [onAccepted].
// On decline → calls [onDeclined] (typically exits or shows blocked screen).

import 'package:flutter/material.dart';

import 'package:ai_orchestrator/core/app_legal/services/eula_service.dart';
import 'package:ai_orchestrator/core/app_legal/ui/widgets/eula_content_widget.dart';

class EulaPage extends StatefulWidget {
  const EulaPage({
    super.key,
    required this.eulaService,
    required this.onAccepted,
    required this.onDeclined,
  });

  final EulaService eulaService;

  /// Called after consent is persisted — navigate to the main app here.
  final VoidCallback onAccepted;

  /// Called when the user taps Decline — show blocked screen or exit.
  final VoidCallback onDeclined;

  @override
  State<EulaPage> createState() => _EulaPageState();
}

class _EulaPageState extends State<EulaPage> {
  bool _checked = false;
  bool _saving = false;

  Future<void> _handleAccept() async {
    if (!_checked || _saving) return;
    setState(() => _saving = true);
    await widget.eulaService.acceptEula();
    if (!mounted) return;
    widget.onAccepted();
  }

  void _handleDecline() {
    widget.onDeclined();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Header(version: EulaService.currentEulaVersion),
            const Divider(color: Color(0xFF2A2A2A), height: 1),
            const Expanded(child: EulaContentWidget()),
            const Divider(color: Color(0xFF2A2A2A), height: 1),
            _Footer(
              checked: _checked,
              saving: _saving,
              onCheckChanged: (v) => setState(() => _checked = v ?? false),
              onAccept: _handleAccept,
              onDecline: _handleDecline,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Private sub-widgets ───────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.version});

  final int version;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF171E33).withValues(alpha: 0.98),
            const Color(0xFF0D0D0D),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFF8AB4F8).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xFF8AB4F8).withValues(alpha: 0.35),
                  ),
                ),
                child: const Icon(
                  Icons.gavel_rounded,
                  color: Color(0xFF8AB4F8),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Beta Software Agreement',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Version $version — Please read carefully before proceeding',
                      style: const TextStyle(
                        color: Color(0xFF8AB4F8),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFFB74D).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: const Color(0xFFFFB74D).withValues(alpha: 0.30),
              ),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: Color(0xFFFFB74D),
                  size: 16,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This is Beta software. You must accept these terms to use the app.',
                    style: TextStyle(
                      color: Color(0xFFFFB74D),
                      fontSize: 11.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.checked,
    required this.saving,
    required this.onCheckChanged,
    required this.onAccept,
    required this.onDecline,
  });

  final bool checked;
  final bool saving;
  final ValueChanged<bool?> onCheckChanged;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      color: const Color(0xFF111111),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Confirmation checkbox
          InkWell(
            onTap: () => onCheckChanged(!checked),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: checked,
                      onChanged: onCheckChanged,
                      activeColor: const Color(0xFF8AB4F8),
                      side: const BorderSide(
                        color: Color(0xFF555555),
                        width: 1.5,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'I have read and accept the Beta Software Agreement',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: saving ? null : onDecline,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFFF8A80),
                    side: const BorderSide(color: Color(0xFF3A3A3A)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Decline'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: (checked && !saving) ? onAccept : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF8AB4F8),
                    foregroundColor: const Color(0xFF0D0D0D),
                    disabledBackgroundColor: const Color(0xFF2A2A2A),
                    disabledForegroundColor: const Color(0xFF555555),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF0D0D0D),
                          ),
                        )
                      : const Text(
                          'Accept & Continue',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
