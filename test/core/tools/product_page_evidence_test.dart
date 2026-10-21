import 'package:ai_orchestrator/core/tools/search/product_page_evidence.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const page = '''<html><script type="application/ld+json">{"@context":"https://schema.org","@type":"Product","name":"Notebook Aurora","description":"Schermo 15 pollici, RAM 16 GB, SSD 512 GB.","offers":{"@type":"Offer","price":"699.00","priceCurrency":"EUR","availability":"https://schema.org/InStock"}}</script></html>''';
  test('extracts source product description, price and availability without model claims', () {
    final result = ProductPageEvidence.parse(page, source: 'https://www.asus.com/product');
    expect(result, contains('Notebook Aurora'));
    expect(result, contains('RAM 16 GB'));
    expect(result, contains('699.00 EUR'));
    expect(result, contains('Disponibilità dichiarata: disponibile'));
    expect(result, contains('https://www.asus.com/product'));
    expect(result, isNot(contains('799')));
  });
  test('ambiguous category pages, malformed data and missing attributes do not invent a product', () {
    expect(ProductPageEvidence.parse('$page$page', source: 'https://www.asus.com/category'), isNull);
    expect(ProductPageEvidence.parse('<html>captcha or no data</html>', source: 'https://www.asus.com/product'), isNull);
    expect(ProductPageEvidence.parse('<script type="application/ld+json">{"@type":"Product","name":"Only a title"}</script>', source: 'https://www.asus.com/product'), isNull);
  });
  test('reads supported retail page, rejects redirects and private or tracking destinations', () async {
    var calls = 0;
    final client = MockClient((request) async { calls++; return http.Response(page, 200); });
    expect(await ProductPageEvidence.read('https://www.asus.com/product', client: client), contains('699.00 EUR'));
    expect(await ProductPageEvidence.read('http://127.0.0.1/private', client: client), isNull);
    expect(await ProductPageEvidence.read('https://duckduckgo.com/y.js?ad_domain=asus.com', client: client), isNull);
    expect(await ProductPageEvidence.read('https://www.asus.com.evil.test/product', client: client), isNull);
    expect(calls, 1);
    expect(await ProductPageEvidence.read('https://www.asus.com/product', client: MockClient((_) async => http.Response('', 302, headers: {'location':'http://127.0.0.1/'}))), isNull);
  });
  test('oversized source is discarded before structured data is used', () async {
    final client = MockClient((_) async => http.Response('$page${List.filled(600000, 'x').join()}', 200));
    expect(await ProductPageEvidence.read('https://www.asus.com/product', client: client), isNull);
  });
}
