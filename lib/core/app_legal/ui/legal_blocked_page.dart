// AppLegalCore — Permanent blocked screen shown when a user declines the EULA.
//
// This screen has no navigation back to the rest of the app.  The only
// affordance offered is "Exit App" (via [SystemNavigator.pop]) and, optionally,
// "Review Agreement" which pops back to the EULA page so the user may reconsider.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class LegalBlockedPage extends StatelessWidget {
  const LegalBlockedPage({
    super.key,
    this.onReviewAgreement,
  });

  /// If non-null a "Review Agreement" button is shown that invokes this callback.
  final VoidCallback? onReviewAgreement;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Prevent hardware back button from bypassing this screen.
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D0D),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF5252).withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFFFF5252).withValues(alpha: 0.35),
                        width: 1.5,
                      ),
                    ),
                    child: const Icon(
                      Icons.block_rounded,
                      color: Color(0xFFFF5252),
                      size: 36,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Access Denied',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'You must accept the Beta Software Agreement to use this '
                    'application. Without acceptance, the app cannot be used.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF999999),
                      fontSize: 14,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 32),
                  if (onReviewAgreement != null) ...[
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: onReviewAgreement,
                        icon: const Icon(Icons.article_outlined, size: 18),
                        label: const Text('Review Agreement'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF8AB4F8),
                          foregroundColor: const Color(0xFF0D0D0D),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => SystemNavigator.pop(),
                      icon: const Icon(Icons.exit_to_app_rounded, size: 18),
                      label: const Text('Exit App'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFFF8A80),
                        side: const BorderSide(color: Color(0xFF3A3A3A)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
