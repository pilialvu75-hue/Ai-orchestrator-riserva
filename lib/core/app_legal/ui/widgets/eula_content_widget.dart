// AppLegalCore — Scrollable EULA body widget.
//
// Encapsulates the full Beta Software Agreement text so that [EulaPage] stays
// focused on layout concerns.  The text is structured to be easily replaced
// with a Markdown renderer or a remote document in the future.

import 'package:flutter/material.dart';

class EulaContentWidget extends StatelessWidget {
  const EulaContentWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return const SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: _EulaText(),
    );
  }
}

class _EulaText extends StatelessWidget {
  const _EulaText();

  @override
  Widget build(BuildContext context) {
    const bodyStyle = TextStyle(
      color: Color(0xFFCCCCCC),
      fontSize: 13.5,
      height: 1.65,
    );
    const headingStyle = TextStyle(
      color: Colors.white,
      fontSize: 14,
      fontWeight: FontWeight.w700,
      height: 2.0,
    );
    const subStyle = TextStyle(
      color: Color(0xFFAAAAAA),
      fontSize: 12.5,
      fontStyle: FontStyle.italic,
      height: 1.5,
    );

    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Last updated: 2025 — Version 1',
          style: subStyle,
        ),
        SizedBox(height: 12),
        Text('1. Beta Software — Experimental Use', style: headingStyle),
        Text(
          'This application is currently in Beta / experimental stage. '
          'It is provided "as is" without warranty of any kind, either '
          'express or implied, including but not limited to the warranties '
          'of merchantability, fitness for a particular purpose, or '
          'non-infringement.',
          style: bodyStyle,
        ),
        Text('2. Risk of Data Loss & Malfunctions', style: headingStyle),
        Text(
          'You acknowledge that this software may experience crashes, '
          'data loss, or unexpected behaviour. The developer cannot be '
          'held liable for any direct or indirect damages arising from '
          'the use of this application.',
          style: bodyStyle,
        ),
        Text('3. AI Feature Instability', style: headingStyle),
        Text(
          'Certain AI-powered features may be unstable, incomplete, or '
          'produce inaccurate results. You agree to use all AI outputs '
          'critically and at your own risk.',
          style: bodyStyle,
        ),
        Text('4. Acceptance of Risk', style: headingStyle),
        Text(
          'By using this application you expressly acknowledge and accept '
          'all associated risks, including but not limited to data loss, '
          'unexpected behaviour, and the experimental nature of AI features.',
          style: bodyStyle,
        ),
        Text('5. Diagnostic Data', style: headingStyle),
        Text(
          'You agree to the anonymous collection and transmission of '
          'diagnostic logs and crash reports solely for the purpose of '
          'improving application stability. No personally identifiable '
          'information (PII) is collected or transmitted. Diagnostic data '
          'does not include the content of your conversations or any '
          'personal documents.',
          style: bodyStyle,
        ),
        Text('6. Remote Feature Management', style: headingStyle),
        Text(
          'The developer reserves the right to enable, disable, or modify '
          'application features remotely via software updates or feature '
          'flags without prior notice.',
          style: bodyStyle,
        ),
        Text('7. No Sensitive Data', style: headingStyle),
        Text(
          'You agree not to input, store, or process sensitive personal '
          'data (including health, financial, or government-issued '
          'identification data) within this application during the Beta '
          'period.',
          style: bodyStyle,
        ),
        Text('8. Updates to this Agreement', style: headingStyle),
        Text(
          'This agreement may be updated at any time. When a new version '
          'is published you will be required to review and accept the '
          'updated terms before continuing to use the application.',
          style: bodyStyle,
        ),
        SizedBox(height: 20),
      ],
    );
  }
}
