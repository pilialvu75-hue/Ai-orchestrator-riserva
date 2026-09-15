import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_pinned_dns_resolver.dart';

void main() {
  test('reuses the same DNS snapshot inside the pin TTL', () async {
    var lookups = 0;
    var now = DateTime.utc(2026, 9, 15, 12);
    final resolver = WorkshopPinnedDnsResolver(
      lookup: (host) async {
        lookups += 1;
        expect(host, 'example.com');
        return <InternetAddress>[
          InternetAddress(lookups == 1 ? '93.184.216.34' : '192.168.1.42'),
        ];
      },
      clock: () => now,
      ttl: const Duration(seconds: 30),
    );

    final validationAddresses = await resolver.resolve('EXAMPLE.COM');
    final connectionAddresses = await resolver.resolve('example.com');

    expect(lookups, 1);
    expect(validationAddresses.single.address, '93.184.216.34');
    expect(connectionAddresses.single.address, '93.184.216.34');

    now = now.add(const Duration(seconds: 31));
    final refreshed = await resolver.resolve('example.com');

    expect(lookups, 2);
    expect(refreshed.single.address, '192.168.1.42');
  });

  test('clear forces a fresh DNS snapshot', () async {
    var lookups = 0;
    final resolver = WorkshopPinnedDnsResolver(
      lookup: (_) async {
        lookups += 1;
        return <InternetAddress>[InternetAddress('93.184.216.34')];
      },
    );

    await resolver.resolve('example.com');
    resolver.clear();
    await resolver.resolve('example.com');

    expect(lookups, 2);
  });
}
