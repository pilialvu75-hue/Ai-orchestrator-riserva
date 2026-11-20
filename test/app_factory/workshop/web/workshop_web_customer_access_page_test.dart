import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_customer_access_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('owner can create, list and revoke a time-limited invitation',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1050, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const id = '11111111-1111-4111-8111-111111111111';
    String? inviteStatus;
    int createCalls = 0;
    int revokeCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/cantiere/access/status') {
        return http.Response(jsonEncode({
          'version': 1, 'ok': true, 'role': 'owner',
          'clientEnabled': false, 'canUseStudio': true,
        }), 200);
      }
      if (request.url.path == '/api/cantiere/access/invitations') {
        if (request.method == 'GET') {
          return http.Response(jsonEncode({
            'version': 1, 'ok': true, 'invitations': [
              if (inviteStatus != null) {
                'invitationId': id, 'recipientEmail': 'alice@example.test',
                'status': inviteStatus, 'linked': false,
                'expiresAt': '2026-11-23T10:00:00Z',
              },
            ],
          }), 200);
        }
        createCalls++;
        final body = jsonDecode(request.body);
        expect(body, {'email': 'alice@example.test', 'expiresDays': 7});
        inviteStatus = 'pending';
        return http.Response(jsonEncode({
          'version': 1, 'ok': true,
          'status': 'pending', 'invitationId': id,
        }), 200);
      }
      expect(request.url.path, '/api/cantiere/access/revoke');
      expect(request.method, 'POST');
      expect(jsonDecode(request.body), {'invitationId': id});
      revokeCalls++;
      inviteStatus = 'revoked';
      return http.Response(jsonEncode({
        'version': 1, 'ok': true, 'status': 'revoked',
      }), 200);
    });
    await tester.pumpWidget(MaterialApp(
      home: WorkshopWebCustomerAccessPage(client: client),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Proprietario AIVEXUS'), findsOneWidget);
    expect(find.text('Nessun invito disponibile.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('web_customer_email')),
      'alice@example.test',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('web_customer_create')));
    await tester.pumpAndSettle();
    expect(createCalls, 1);
    expect(find.byKey(const Key('web_customer_notice')), findsOneWidget);
    expect(find.text('alice@example.test'), findsOneWidget);
    expect(find.byKey(const Key('web_customer_copy_' + id)), findsOneWidget);
    await tester.tap(find.byTooltip('Revoca accesso'));
    await tester.pumpAndSettle();
    expect(revokeCalls, 1);
    expect(find.byTooltip('Revoca accesso'), findsNothing);
    expect(find.textContaining('revoked'), findsOneWidget);
  });

  testWidgets('Access-verified invitee can accept but cannot auto-open customer mode',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 860);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const id = '11111111-1111-4111-8111-111111111111';
    bool accepted = false;
    int claims = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/cantiere/access/status') {
        return http.Response(jsonEncode({
          'version': 1, 'ok': true,
          'role': accepted ? 'client' : 'uninvited',
          'clientEnabled': false,
          'canUseStudio': false,
        }), 200);
      }
      expect(request.url.path, '/api/cantiere/access/claim');
      expect(request.method, 'POST');
      expect(jsonDecode(request.body), {'invitationId': id});
      claims++;
      accepted = true;
      return http.Response(jsonEncode({
        'version': 1, 'ok': true, 'status': 'accepted',
      }), 200);
    });
    await tester.pumpWidget(MaterialApp(
      home: WorkshopWebCustomerAccessPage(client: client, invitationId: id),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('web_customer_claim')), findsOneWidget);
    await tester.tap(find.byKey(const Key('web_customer_claim')));
    await tester.pumpAndSettle();
    expect(claims, 1);
    expect(find.textContaining('L’apertura ai clienti non è ancora attiva.'),
        findsOneWidget);
    expect(find.byKey(const Key('web_customer_claim')), findsNothing);
  });
}
