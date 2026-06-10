import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';
import 'package:ai_orchestrator/core/config/storage/preferences_service.dart';
import 'package:ai_orchestrator/core/runtime/ai_runtime_settings.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/features/chat_memory/domain/memory_window_config.dart';
import 'package:ai_orchestrator/features/settings/presentation/pages/modules/token_configurator_page.dart';

Future<AiRuntimeSettingsService> _createService(
  Map<String, Object> values,
) async {
  SharedPreferences.setMockInitialValues(values);
  final preferences = await SharedPreferences.getInstance();
  return AiRuntimeSettingsService(
    configRepository: ConfigRepository(PreferencesService(preferences)),
  );
}

Widget _wrap(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
    supportedLocales: const [Locale('en')],
    localizationsDelegates: const [AppLocalizations.delegate],
    home: child,
  );
}

void main() {
  group('TokenConfiguratorPage', () {
    testWidgets('shows sliders only for custom profile', (tester) async {
      final compactService = await _createService(<String, Object>{
        AppConstants.prefMemoryWindowProfile: 'compact',
      });
      await tester.pumpWidget(
        _wrap(TokenConfiguratorPage(
          settingsService: compactService,
          isWeb: false,
        )),
      );

      expect(find.byType(Slider), findsNothing);

      final customService = await _createService(<String, Object>{
        AppConstants.prefMemoryWindowProfile: 'custom',
        AppConstants.prefMemoryWindowCustomTokenBudget: '12000',
        AppConstants.prefMemoryWindowCustomLineBudget: '72',
      });
      await tester.pumpWidget(
        _wrap(TokenConfiguratorPage(
          settingsService: customService,
          isWeb: false,
        )),
      );

      expect(find.byType(Slider), findsNWidgets(2));
    });

    testWidgets('shows a web warning for large custom budgets', (tester) async {
      final service = await _createService(<String, Object>{
        AppConstants.prefMemoryWindowProfile: 'custom',
        AppConstants.prefMemoryWindowCustomTokenBudget: '12000',
        AppConstants.prefMemoryWindowCustomLineBudget: '72',
      });
      await tester.pumpWidget(
        _wrap(TokenConfiguratorPage(
          settingsService: service,
          isWeb: true,
        )),
      );

      expect(find.textContaining('Web safety clamp'), findsOneWidget);
    });

    testWidgets('maps dropdown options to persisted profiles', (tester) async {
      final service = await _createService(<String, Object>{
        AppConstants.prefMemoryWindowProfile: 'automatic',
      });
      await tester.pumpWidget(
        _wrap(TokenConfiguratorPage(
          settingsService: service,
          isWeb: false,
        )),
      );

      await tester.tap(find.byKey(const Key('memory-window-profile-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('16K').last);
      await tester.pumpAndSettle();

      expect(service.memoryWindowProfile, MemoryWindowProfile.performance);
    });
  });
}
