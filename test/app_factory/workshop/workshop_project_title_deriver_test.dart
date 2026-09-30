import 'package:flutter_test/flutter_test.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_project_title_deriver.dart';

void main() {
  group('WorkshopProjectTitleDeriver', () {
    test('uses explicit Italian app name instead of the whole prompt', () {
      expect(
        WorkshopProjectTitleDeriver.derive(
          'Crea una semplice app Flutter per Android chiamata Contatore Test. '
          'Mostra al centro un numero inizialmente a zero.',
        ),
        'Contatore Test',
      );
    });

    test('supports a quoted explicit name', () {
      expect(
        WorkshopProjectTitleDeriver.derive(
          'Crea una app chiamata “Contatore Test” con due pulsanti.',
        ),
        'Contatore Test',
      );
    });

    test('supports an English explicit name', () {
      expect(
        WorkshopProjectTitleDeriver.derive(
          'Create a Flutter app called Walking Tracker with a simple counter.',
        ),
        'Walking Tracker',
      );
    });

    test('keeps bounded prompt fallback when no explicit name exists', () {
      const prompt =
          'Crea una nuova app note con aggiunta, modifica ed eliminazione.';
      expect(
        WorkshopProjectTitleDeriver.derive(prompt),
        startsWith('Crea una nuova app note'),
      );
      expect(
        WorkshopProjectTitleDeriver.derive(prompt).length,
        lessThanOrEqualTo(48),
      );
    });

    test('uses default title for empty instruction', () {
      expect(
        WorkshopProjectTitleDeriver.derive('   '),
        'Nuova produzione Cantiere',
      );
    });
  });
}
