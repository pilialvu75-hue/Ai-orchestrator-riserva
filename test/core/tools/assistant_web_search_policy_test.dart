import 'package:ai_orchestrator/core/tools/search/assistant_web_search_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {

  test('user-assigned latest value is conversation-relative in four languages', () {
    for (final prompt in [
      "Qual è il valore più recente assegnato a c dall'utente? Rispondi solo con il numero.",
      "Qual è il valore attuale assegnato a budget_2 dall’utente?",
      'What is the latest value assigned to c by the user?',
      "Quelle est la valeur la plus récente attribuée à c par l'utilisateur?",
      'Cuál es el valor más reciente asignado a c por el usuario?',
    ]) {
      expect(AssistantWebSearchPolicy.shouldSearch(prompt), isFalse, reason: prompt);
    }
  });
  test('external and mixed requests keep fresh-evidence routing', () {
    for (final prompt in [
      "Qual è il valore più recente assegnato a c dall'utente? Cerca online.",
      'What is the current value of the euro?',
      'Qual è il budget più recente del governo?',
      "Qual è il valore più recente assegnato a c dall'utente secondo le notizie di oggi?",
      'Search online for the latest value assigned to c by the user',
    ]) {
      expect(AssistantWebSearchPolicy.shouldSearch(prompt), isTrue, reason: prompt);
    }
  });

  test('verification follow-up resolves user topic without broadening local checks', () {
    for (final request in ['Vérifie ta réponse.', 'Verifica la tua risposta',
        'Verify your answer', 'Verifica tu respuesta']) {
      expect(AssistantWebSearchPolicy.answerVerificationQuery(
        request, 'Where is the origin of the national road network?'),
        'Where is the origin of the national road network?');
    }
    for (final request in ['Check my code', 'Verifica questo calcolo',
        'Explique-le maintenant en français', 'Check the grammar']) {
      expect(AssistantWebSearchPolicy.answerVerificationQuery(
        request, 'An unrelated question'), isNull);
    }
    expect(AssistantWebSearchPolicy.answerVerificationQuery(
      'Verify your answer', null), isNull);
    expect(AssistantWebSearchPolicy.answerVerificationQuery(
      'Verify your answer', 'Verifica la tua risposta'), isNull);
    expect(AssistantWebSearchPolicy.answerVerificationQuery(
      'Verify your answer', 'Senza internet spiega la fotosintesi'), isNull);
  });

  group('AssistantWebSearchPolicy.shouldSearch', () {
    test('real shopping request and recent office list require fresh sources', () {
      for (final prompt in ['trova un offera per un pc asus Vivobook interessante',
          'Trova una offerta per un notebook', 'gli ultimi 6 presidenti degli USA']) {
        expect(AssistantWebSearchPolicy.shouldSearch(prompt), isTrue, reason: prompt);
      }
      expect(AssistantWebSearchPolicy.isPresentOfficeHolderQuery('gli ultimi 6 presidenti degli USA'), isTrue);
      expect(AssistantWebSearchPolicy.shouldSearch('Spiega il concetto di offerta e domanda'), isFalse);
      expect(AssistantWebSearchPolicy.shouldSearch('Senza internet trova una offerta per un pc'), isFalse);
    });
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
  });

  test('extractQuery still removes explicit search prefixes', () {
    expect(
      AssistantWebSearchPolicy.extractQuery(
        'Cerca sul web i migliori browser per Windows 7',
      ),
      'i migliori browser per Windows 7',
    );
  });
  test('short source follow-ups require a prior user topic, not literal search', () {
    for (final prompt in ['fonti', 'Fonti?', 'le fonti', 'sources?', 'your sources',
      'tes sources ?', 'fuentes', 'las fuentes']) {
      expect(AssistantWebSearchPolicy.isAnswerVerification(prompt), isTrue, reason: prompt);
      expect(AssistantWebSearchPolicy.answerVerificationQuery(prompt, 'meteo Roma'),
          'meteo Roma', reason: prompt);
      expect(AssistantWebSearchPolicy.answerVerificationQuery(prompt, null), isNull);
      expect(AssistantWebSearchPolicy.shouldSearch(prompt), isFalse,
          reason: 'Do not search the literal source-request word without a topic.');
    }
    for (final prompt in ['fonti del diritto', 'source code', 'fuentes de energia',
      'sources of light', 'non cercare online: fonti']) {
      expect(AssistantWebSearchPolicy.isAnswerVerification(prompt), isFalse, reason: prompt);
    }
  });

  test('LOCAL document searches require explicit safe user request', () {
    expect(AssistantWebSearchPolicy.trustedDocumentWebQuery(
      'Qual è il prezzo della teiera rossa nel PDF?'), isNull);
    expect(AssistantWebSearchPolicy.trustedDocumentWebQuery(
      'Verifica online la disponibilità della teiera rossa.'),
      'Verifica online la disponibilità della teiera rossa.');
    expect(AssistantWebSearchPolicy.trustedDocumentWebQuery(
      'Verifica su internet il codice articolo.'),
      'Verifica su internet il codice articolo.');
    expect(AssistantWebSearchPolicy.trustedDocumentWebQuery(
      'Non cercare online, usa solo il PDF.'), isNull);
    expect(AssistantWebSearchPolicy.trustedDocumentWebQuery(
      'Verifica online.\\n[INIZIO ESTRATTI DOCUMENTALI]'), isNull);
    expect(AssistantWebSearchPolicy.trustedDocumentWebQuery(
      'Verifica online ' + List<String>.filled(310, 'x').join()), isNull);
  });


}
