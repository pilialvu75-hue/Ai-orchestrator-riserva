import 'search_provider.dart';

class SearchContextBuilder {
  /// Trasforma una lista di risultati web in un blocco di contesto ottimizzato per i prompt locali.
  static String buildPromptContext(List<SearchResult> results, String originalQuery) {
    if (results.isEmpty) {
      return "\n[SISTEMA]: Nessuna informazione aggiuntiva trovata online per la query '$originalQuery'. Rispondi basandoti solo sulle tue conoscenze interne.\n";
    }

    final buffer = StringBuffer();
    buffer.writeln("\n--- INIZIO DATI DAL WEB (Query: '$originalQuery') ---");
    
    for (int i = 0; i < results.length; i++) {
      final res = results[i];
      buffer.writeln("Fonte [${i + 1}]: ${res.title}");
      buffer.writeln("URL: ${res.url}");
      buffer.writeln("Contenuto: ${res.snippet}\n");
    }
    
    buffer.writeln("--- FINE DATI DAL WEB ---");
    buffer.writeln("Istruzione: Rispondi alla domanda dell'utente utilizzando esclusivamente i dati sopra riportati dove rilevante. Cita la fonte [1], [2], ecc. se usi informazioni specifiche.\n");
    
    return buffer.toString();
  }
}
