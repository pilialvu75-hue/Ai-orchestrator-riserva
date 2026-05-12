import 'package:ai_orchestrator/core/config/app/environment_config.dart';

class AppConfig {
  const AppConfig({required this.environment});

  final EnvironmentConfig environment;

  static const AppConfig current = AppConfig(
    environment: EnvironmentConfig.current,
  );
}
