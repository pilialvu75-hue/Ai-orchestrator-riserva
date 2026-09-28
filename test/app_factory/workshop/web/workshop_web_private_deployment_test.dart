import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('W2 routes every Pages request through authentication middleware', () {
    final raw = File('web/_routes.json').readAsStringSync();
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    expect(decoded['version'], 1);
    expect(decoded['include'], <String>['/*']);
    expect(decoded['exclude'], isEmpty);
  });

  test('W2 middleware fails closed and reads only server-side secrets', () {
    final source = File('functions/_middleware.js').readAsStringSync();

    expect(source, contains('context.env.WEB_ACCESS_USER'));
    expect(source, contains('context.env.WEB_ACCESS_PASSWORD'));
    expect(source, contains('status: 503'));
    expect(source, contains('status: 401'));
    expect(source, contains('context.next()'));

    // The authoritative expected credentials must come from Pages secrets.
    expect(
      source,
      contains('expectedUser = context.env.WEB_ACCESS_USER'),
    );
    expect(
      source,
      contains('expectedPassword = context.env.WEB_ACCESS_PASSWORD'),
    );
  });

  test('private deploy verifies both denial and authenticated access', () {
    final workflow =
        File('.github/workflows/web-private-deploy.yml').readAsStringSync();

    expect(workflow, contains('WEB_ACCESS_USER'));
    expect(workflow, contains('WEB_ACCESS_PASSWORD'));
    expect(workflow, contains('test "$root_status" = "401"'));
    expect(workflow, contains('test "$asset_status" = "401"'));
    expect(workflow, contains('test "$root_status" = "200"'));
    expect(workflow, contains('test "$asset_status" = "200"'));
  });
}
