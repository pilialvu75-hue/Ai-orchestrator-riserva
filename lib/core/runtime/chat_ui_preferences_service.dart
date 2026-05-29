import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/core/config/storage/config_repository.dart';

enum AssistantMessageTextSize {
  small(13),
  medium(15),
  large(18);

  const AssistantMessageTextSize(this.fontSize);

  final double fontSize;

  static AssistantMessageTextSize fromStorage(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    return AssistantMessageTextSize.values.firstWhere(
      (candidate) => candidate.name == normalized,
      orElse: () => AssistantMessageTextSize.medium,
    );
  }
}

class ChatUiPreferencesService {
  ChatUiPreferencesService({required ConfigRepository configRepository})
      : _configRepository = configRepository;

  final ConfigRepository _configRepository;

  AssistantMessageTextSize get assistantMessageTextSize =>
      AssistantMessageTextSize.fromStorage(
        _configRepository.getString(AppConstants.prefAssistantTextSize),
      );

  Future<void> setAssistantMessageTextSize(
    AssistantMessageTextSize size,
  ) async {
    await _configRepository.setString(
      AppConstants.prefAssistantTextSize,
      size.name,
    );
  }
}
