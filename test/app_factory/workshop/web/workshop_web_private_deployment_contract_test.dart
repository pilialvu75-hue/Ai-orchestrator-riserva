import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('W2 deployment stays manual and requires Cloudflare Access preflight', () {
    final workflow = File(
      '.github/workflows/web-private-deploy.yml',
    ).readAsStringSync();

    expect(workflow, contains('workflow_dispatch:'));
    expect(workflow, isNot(contains('\n  push:')));
    expect(workflow, contains('DEPLOY_PRIVATE_CANTIERE'));
    expect(workflow, contains('CLOUDFLARE_ACCOUNT_ID'));
    expect(workflow, contains('CLOUDFLARE_API_TOKEN'));
    expect(workflow, contains('CLOUDFLARE_PAGES_PROJECT'));
    expect(workflow, contains('w2-access-probe.'));
    expect(workflow, contains('.pages.dev'));
    expect(workflow, contains('cloudflare/wrangler-action@v4'));
    expect(workflow, contains('steps.deploy.outputs.deployment-url'));
    expect(workflow, contains('cloudflareaccess.com'));
    expect(workflow, contains('/cdn-cgi/access/'));
  });

  test('W2 static headers prevent indexing and basic browser embedding', () {
    final headers = File('web/_headers').readAsStringSync();

    expect(headers, contains('X-Robots-Tag: noindex'));
    expect(headers, contains('X-Frame-Options: DENY'));
    expect(headers, contains('X-Content-Type-Options: nosniff'));
    expect(headers, contains('Referrer-Policy: no-referrer'));
  });
}
