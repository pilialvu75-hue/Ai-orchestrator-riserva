import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ai_orchestrator/app_factory/workshop/workshop_pinned_public_http_client.dart';

void main() {
  group('WorkshopPinnedPublicHttpClient', () {
    test('classifies public and non-public IPv4 ranges', () {
      expect(
        WorkshopPinnedPublicHttpClient.isPublicAddress(
          InternetAddress('8.8.8.8'),
        ),
        isTrue,
      );
      expect(
        WorkshopPinnedPublicHttpClient.isPublicAddress(
          InternetAddress('1.1.1.1'),
        ),
        isTrue,
      );

      for (final value in <String>[
        '0.0.0.1',
        '10.0.0.1',
        '100.64.0.1',
        '127.0.0.1',
        '169.254.1.1',
        '172.16.0.1',
        '192.168.1.1',
        '192.0.2.1',
        '198.18.0.1',
        '198.51.100.1',
        '203.0.113.1',
        '224.0.0.1',
      ]) {
        expect(
          WorkshopPinnedPublicHttpClient.isPublicAddress(
            InternetAddress(value),
          ),
          isFalse,
          reason: value,
        );
      }
    });

    test('classifies public and non-public IPv6 ranges', () {
      expect(
        WorkshopPinnedPublicHttpClient.isPublicAddress(
          InternetAddress('2606:4700:4700::1111'),
        ),
        isTrue,
      );

      for (final value in <String>[
        '::',
        '::1',
        'fc00::1',
        'fd00::1',
        'fe80::1',
        'ff02::1',
        '2001:db8::1',
        '::ffff:127.0.0.1',
        '::ffff:192.168.1.10',
      ]) {
        expect(
          WorkshopPinnedPublicHttpClient.isPublicAddress(
            InternetAddress(value),
          ),
          isFalse,
          reason: value,
        );
      }
    });

    test('private DNS result fails before any network connection can succeed',
        () async {
      var resolverCalls = 0;
      final client = WorkshopPinnedPublicHttpClient(
        resolver: (host) async {
          resolverCalls += 1;
          expect(host, 'example.com');
          return <InternetAddress>[InternetAddress('192.168.1.42')];
        },
      );
      addTearDown(client.close);

      final request = http.Request(
        'GET',
        Uri.parse('https://example.com/research'),
      );

      await expectLater(client.send(request), throwsA(anything));
      expect(resolverCalls, 1);
    });

    test('mixed public and private DNS result fails closed', () async {
      var resolverCalls = 0;
      final client = WorkshopPinnedPublicHttpClient(
        resolver: (host) async {
          resolverCalls += 1;
          expect(host, 'example.com');
          return <InternetAddress>[
            InternetAddress('93.184.216.34'),
            InternetAddress('192.168.1.42'),
          ];
        },
      );
      addTearDown(client.close);

      final request = http.Request(
        'GET',
        Uri.parse('https://example.com/research'),
      );

      await expectLater(client.send(request), throwsA(anything));
      expect(resolverCalls, 1);
    });

    test('literal loopback fails without invoking DNS resolver', () async {
      var resolverCalls = 0;
      final client = WorkshopPinnedPublicHttpClient(
        resolver: (_) async {
          resolverCalls += 1;
          return <InternetAddress>[InternetAddress('8.8.8.8')];
        },
      );
      addTearDown(client.close);

      final request = http.Request(
        'GET',
        Uri.parse('http://127.0.0.1/private'),
      );

      await expectLater(client.send(request), throwsA(anything));
      expect(resolverCalls, 0);
    });
  });
}
