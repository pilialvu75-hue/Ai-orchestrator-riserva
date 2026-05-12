enum AppEnvironment { development, staging, production }

class EnvironmentConfig {
  const EnvironmentConfig({required this.environment});

  final AppEnvironment environment;

  bool get isProduction => environment == AppEnvironment.production;

  static const EnvironmentConfig current = EnvironmentConfig(
    environment: AppEnvironment.production,
  );
}
