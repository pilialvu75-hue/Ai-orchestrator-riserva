import 'package:flutter_test/flutter_test.dart';
import 'package:ai_orchestrator/core/voice/tts_text_plan.dart';

void main() {
  test('routes full foreign text independently from app language', () {
    expect(detectTtsLanguage('Bonjour, comment allez-vous?', 'it'), 'fr');
    expect(detectTtsLanguage('Hello, how are you today?', 'it'), 'en');
    expect(detectTtsLanguage('Ciao, come stai? Questa è la risposta.', 'fr'), 'it');
    expect(detectTtsLanguage('Voici votre réponse en français.', 'it'), 'fr');
  });
  test('names numbers and ambiguous words retain the chosen locale', () {
    expect(detectTtsLanguage('Roberto 123', 'fr-FR'), 'fr');
    expect(detectTtsLanguage('Paris', 'it'), 'it');
    expect(detectTtsLanguage('OK', 'de'), 'en');
  });
  test('splits sentences and bounds long phrases without losing words', () {
    const text = 'Prima frase. Seconda frase! Il valore è 3.14 e resta intero.';
    final parts = ttsPhrases(text, maxChars: 25);
    expect(parts.first, 'Prima frase.');
    expect(parts.join(' '), text);
    expect(parts.every((p) => p.length <= 25), isTrue);
    expect(parts.join(' '), contains('3.14'));
    expect(ttsPhrases('   '), isEmpty);
  });
}
