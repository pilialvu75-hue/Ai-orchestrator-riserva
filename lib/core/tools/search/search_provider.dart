import 'package:meta/meta.dart';

const int searchResultsLimit = 8;

@immutable
class SearchResult {
  const SearchResult({
    required this.title,
    required this.url,
    required this.snippet,
  });

  final String title;
  final String url;
  final String snippet;
}

abstract class SearchProvider {
  Duration get timeout;

  Future<List<SearchResult>> search(
    String query, {
    int limit = 5,
  });
}
