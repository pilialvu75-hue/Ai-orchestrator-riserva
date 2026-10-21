import 'dart:convert';
import 'package:http/http.dart' as http;

/// Reads declared product data, not scripts or model-generated attributes.
/// Unsupported, blocked, ambiguous or oversized pages yield no product claim.
abstract final class ProductPageEvidence {
  static bool _allowed(Uri uri) {
    const retailers = ['asus.com', 'amazon.it', 'amazon.fr', 'amazon.de',
      'amazon.es', 'amazon.com', 'unieuro.it', 'mediaworld.it', 'euronics.it'];
    final host = uri.host.toLowerCase();
    return uri.scheme == 'https' && uri.userInfo.isEmpty && uri.port == 443 &&
        retailers.any((domain) => host == domain || host.endsWith('.$domain'));
  }

  static Future<String?> read(String url, {http.Client? client}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !_allowed(uri)) return null;
    final owned = client == null;
    final transport = client ?? http.Client();
    try {
      return await (() async {
        final response = await transport.send(http.Request('GET', uri)..followRedirects = false);
        if (response.statusCode != 200) return null;
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 512 * 1024) return null;
          bytes.addAll(chunk);
        }
        return parse(utf8.decode(bytes, allowMalformed: true), source: uri.toString());
      })().timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    } finally {
      if (owned) transport.close();
    }
  }

  static String? parse(String html, {required String source}) {
    final candidates = <Map>[];
    void visit(Object? node) {
      if (node is List) {
        for (final value in node) { visit(value); }
      } else if (node is Map) {
        final type = node['@type'];
        final types = type is List ? type : [type];
        if (types.any((t) => t is String && t.split('/').last == 'Product')) {
          candidates.add(node);
        } else {
          for (final key in ['@graph', 'mainEntity', 'itemListElement', 'item']) {
            visit(node[key]);
          }
        }
      }
    }
    final scripts = RegExp(r'''<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>([\s\S]*?)</script>''', caseSensitive: false);
    for (final match in scripts.allMatches(html)) {
      try { visit(jsonDecode(match.group(1)!)); } catch (_) { /* Not valid structured data. */ }
    }
    // A category page or recommendation carousel is not a single product.
    if (candidates.length != 1) return null;
    final product = candidates.single;
    String clean(Object? value, int max) {
      if (value is! String) return '';
      final text = value.replaceAll(RegExp(r'<[^>]*>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ').trim();
      return text.length <= max ? text : '${text.substring(0, max)}…';
    }
    final name = clean(product['name'], 160);
    final description = clean(product['description'], 280);
    final rawOffer = product['offers'];
    final offer = rawOffer is Map ? rawOffer : rawOffer is List && rawOffer.length == 1 && rawOffer.single is Map ? rawOffer.single as Map : null;
    final rawPrice = offer?['price']?.toString() ?? '';
    final currency = offer?['priceCurrency']?.toString() ?? '';
    final price = RegExp(r'^\d{1,7}(?:\.\d{1,2})?$').hasMatch(rawPrice) &&
        RegExp(r'^[A-Z]{3}$').hasMatch(currency) ? '$rawPrice $currency' : null;
    if (name.isEmpty || description.isEmpty && price == null) return null;
    final availability = (offer?['availability']?.toString() ?? '').split('/').last;
    const stock = {'InStock': 'disponibile', 'OutOfStock': 'non disponibile',
      'PreOrder': 'in preordine', 'LimitedAvailability': 'disponibilità limitata'};
    return [name, if (description.isNotEmpty) description,
      if (price != null) 'Prezzo riportato dalla pagina: $price.' else 'Prezzo non verificabile dalla pagina.',
      if (stock.containsKey(availability)) 'Disponibilità dichiarata: ${stock[availability]}.',
      source].join('\n');
  }
}
