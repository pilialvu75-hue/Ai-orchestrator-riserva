import 'package:ai_orchestrator/core/tools/search/assistant_web_search_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AssistantWebSearchPolicy.shouldSearch', () {
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
}
