import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('W2 deployment requires an explicit trigger and Access preflight', () {
    final workflow = File(
      '.github/workflows/web-private-deploy.yml',
    ).readAsStringSync();

    expect(workflow, contains('workflow_dispatch:'));
    expect(workflow, contains('DEPLOY_PRIVATE_CANTIERE'));
    expect(workflow, contains('CLOUDFLARE_ACCOUNT_ID'));
    expect(workflow, contains('CLOUDFLARE_API_TOKEN'));
    expect(workflow, contains('CLOUDFLARE_PAGES_PROJECT'));
    expect(workflow, contains('environment: web-private-production'));
    expect(workflow, contains('w2-access-probe.'));
    expect(workflow, contains('.pages.dev'));
    expect(workflow, contains('cloudflare/wrangler-action@v4'));
    expect(workflow, contains('steps.deploy.outputs.deployment-url'));
    expect(workflow, contains('cloudflareaccess.com'));
    expect(workflow, contains('/cdn-cgi/access/'));
  });

  test('W2 GitOps deploy trigger is narrow, explicit and auditable', () {
    final workflow = File(
      '.github/workflows/web-private-deploy.yml',
    ).readAsStringSync();

    expect(workflow, contains('\n  push:'));
    expect(workflow, contains("      - '.airlab/deploy/web-private-request.json'"));
    expect(workflow, contains('request_file=".airlab/deploy/web-private-request.json"'));
    expect(workflow, contains('.schemaVersion == 1'));
    expect(workflow, contains('.operation == "deploy_private"'));
    expect(workflow, contains('.confirmation == "DEPLOY_PRIVATE_CANTIERE"'));
    expect(workflow, contains('.environment == "web-private-production"'));
    expect(workflow, contains('.requestId'));
    expect(
      workflow,
      contains(
        "github.event_name == 'workflow_dispatch' && inputs.operation == 'deploy_private'",
      ),
    );
    expect(workflow, contains("github.event_name == 'push'"));
  });

  test('W2 bootstrap creates only an empty Pages project and stays manual', () {
    final workflow = File(
      '.github/workflows/web-private-deploy.yml',
    ).readAsStringSync();

    expect(workflow, contains('bootstrap_pages'));
    expect(workflow, contains('BOOTSTRAP_EMPTY_PAGES'));
    expect(workflow, contains('bootstrap-pages:'));
    expect(
      workflow,
      contains(
        "github.event_name == 'workflow_dispatch' && inputs.operation == 'bootstrap_pages'",
      ),
    );
    expect(
      workflow,
      contains(
        'https://api.cloudflare.com/client/v4/accounts/'
        r'${CLOUDFLARE_ACCOUNT_ID}/pages/projects',
      ),
    );
    expect(
      workflow,
      contains(
        'npx --yes wrangler@4 pages project create '
        r'"${CLOUDFLARE_PAGES_PROJECT}"',
      ),
    );
    expect(workflow, contains('--production-branch main'));
    expect(
      workflow,
      contains(
        'Empty Pages project created and verified. No Web assets were uploaded.',
      ),
    );
  });

  test('W2 static headers prevent indexing and basic browser embedding', () {
    final headers = File('web/_headers').readAsStringSync();

    expect(headers, contains('X-Robots-Tag: noindex'));
    expect(headers, contains('X-Frame-Options: DENY'));
    expect(headers, contains('X-Content-Type-Options: nosniff'));
    expect(headers, contains('Referrer-Policy: no-referrer'));
  });
}
