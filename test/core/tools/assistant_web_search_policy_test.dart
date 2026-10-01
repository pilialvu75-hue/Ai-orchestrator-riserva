import 'package:ai_orchestrator/core/tools/search/assistant_web_search_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AssistantWebSearchPolicy.shouldSearch', () {
    test('sports results request evidence, sports rules stay local', () {
      for (final prompt in ['Chi ha vinto il mondiale del 2026?',
          'Who won the 2026 World Cup?', 'Risultati delle olimpiadi']) {
        expect(AssistantWebSearchPolicy.shouldSearch(prompt), isTrue, reason: prompt);
      }
      expect(AssistantWebSearchPolicy.shouldSearch('Spiega le regole del mondiale'), isFalse);
      expect(AssistantWebSearchPolicy.shouldSearch('Come mi chiamo?'), isFalse);
    });
    test('present office-holder identity requires fresh evidence', () {
      for (final prompt in [
        'Chi è il presidente degli Stati Uniti?',
        "Chi e' il presidente della Francia?",
        'Qual è il sindaco di Roma?',
        'Who is the president of the United States?',
        'Who is the prime minister of Canada?',
        'Qui est le président de la France ?',
        'Qui est le premier ministre ?',
        '¿Quién es el presidente de España?',
        'Chi è il primo ministro?',
        'Who is the CEO of Example?',
      ]) {
        expect(AssistantWebSearchPolicy.shouldSearch(prompt), isTrue,
            reason: prompt);
      }
    });
    test('historical offices and explanations do not force a lookup', () {
      for (final prompt in [
        'Chi era il presidente degli Stati Uniti?',
        'Chi è stato il presidente degli Stati Uniti?',
        'Chi è il primo presidente degli Stati Uniti?',
        'Who is the first president of the United States?',
        'Chi è il presidente degli Stati Uniti nel 1990?',
        'Spiega il ruolo del presidente della Repubblica',
        'Ciao, mi chiamo Roberto',
      ]) {
        expect(AssistantWebSearchPolicy.shouldSearch(prompt), isFalse,
            reason: prompt);
      }
    });

    test('searches for Italian ranking and recommendation questions', () {
      expect(
        AssistantWebSearchPolicy.shouldSearch(
          'Chi è il miglior giocatore di calcio?',
        ),
        isTrue,
      );
      expect(
        AssistantWebSearchPolicy.shouldSearch(
          'Quale smartphone mi consigli tra questi due?',
        ),
        isTrue,
      );
      expect(
        AssistantWebSearchPolicy.shouldSearch(
          'Confronta iPhone e Galaxy e dimmi quale scegliere',
        ),
        isTrue,
      );
      expect(
        AssistantWebSearchPolicy.shouldSearch(
          'Cosa ne pensano i forum di questa app?',
        ),
        isTrue,
      );
    });

    test('searches for evidence-driven questions in multiple languages', () {
      expect(
        AssistantWebSearchPolicy.shouldSearch(
          'What is the best laptop for local AI?',
        ),
        isTrue,
      );
      expect(
        AssistantWebSearchPolicy.shouldSearch(
          'Compare these phones using reviews and user opinions',
        ),
        isTrue,
      );
      expect(
        AssistantWebSearchPolicy.shouldSearch(
          'Quel est le meilleur navigateur pour un vieux PC ?',
        ),
        isTrue,
      );
      expect(
        AssistantWebSearchPolicy.shouldSearch(
          '¿Cuál es el mejor móvil y qué dicen las reseñas?',
        ),
        isTrue,
      );
    });

    test('explicit no-web intent overrides dynamic and explicit search words', () {
      for (final prompt in <String>[
        'Non usare internet: dimmi cosa sai delle notizie di oggi.',
        'Non cercare sul web, rispondi solo con quello che sai.',
        'Senza internet, qual è il prezzo che ricordi?',
        'Do not search the web for the latest news.',
        "Don't use internet; answer from local knowledge.",
        "N'utilise pas internet pour les actualités d'aujourd'hui.",
        'No busques en internet el precio actual.',
      ]) {
        expect(
          AssistantWebSearchPolicy.shouldSearch(prompt),
          isFalse,
          reason: prompt,
        );
      }
    });

    test('preserves explicit and time-sensitive web decisions', () {
      expect(
        AssistantWebSearchPolicy.shouldSearch('Cerca sul web Flutter 4'),
        isTrue,
      );
      expect(
        AssistantWebSearchPolicy.shouldSearch('Che tempo fa oggi a Parigi?'),
        isTrue,
      );
      expect(
        AssistantWebSearchPolicy.shouldSearch('Qual è il prezzo attuale?'),
        isTrue,
      );
    });

    test('does not search for stable explanatory prompts by default', () {
      expect(
        AssistantWebSearchPolicy.shouldSearch('Spiegami la fotosintesi'),
        isFalse,
      );
      expect(
        AssistantWebSearchPolicy.shouldSearch(
          'Come migliorare questo algoritmo di ordinamento?',
        ),
        isFalse,
      );
      expect(
        AssistantWebSearchPolicy.shouldSearch(
          'Scrivi una funzione Dart che somma due numeri',
        ),
        isFalse,
      );
    });

    test('generic technical words do not trigger unnecessary web search', () {
      for (final prompt in <String>[
        'Qual è il risultato di 2 + 2?',
        'Prendi l\'ultimo elemento della lista.',
        'What is the current index in this loop?',
        'Spiegami cos\'è il prezzo in economia.',
        'Come calcolo il prezzo medio in Dart?',
      ]) {
        expect(
          AssistantWebSearchPolicy.shouldSearch(prompt),
          isFalse,
          reason: prompt,
        );
      }
    });

    test('fresh versions markets and live sports still request web evidence', () {
      for (final prompt in <String>[
        'Qual è l\'ultima versione di Flutter?',
        'What is the latest release of Dart?',
        'Qual è il prezzo attuale del Bitcoin?',
        'Quanto costa oggi un iPhone 16?',
        'Qual è il risultato della partita di Champions?',
        'Quando gioca la prossima partita di Champions?',
      ]) {
        expect(
          AssistantWebSearchPolicy.shouldSearch(prompt),
          isTrue,
          reason: prompt,
        );
      }
    });
  });

  test('extractQuery still removes explicit search prefixes', () {
    expect(
      AssistantWebSearchPolicy.extractQuery(
        'Cerca sul web i migliori browser per Windows 7',
      ),
      'i migliori browser per Windows 7',
    );
  });
}
