import 'package:ai_orchestrator/app_factory/workshop/workshop_local_toolchain_manager.dart';

/// Piattaforme per le quali il Cantiere può utilizzare una toolchain locale.
///
/// Il catalogo descrive la disponibilità prevista.
/// Non significa che la toolchain sia già installata.
enum WorkshopToolchainPlatform {
  android,
  windows,
  linux,
  macos,
  ios,
}

/// Livello di necessità di un componente.
enum WorkshopToolchainRequirement {
  required,
  optional,
}

/// Descrizione statica di un componente della toolchain.
///
/// Questa classe NON scarica, installa o verifica il componente.
/// Queste responsabilità appartengono rispettivamente al
/// LocalToolchainManager e al LocalToolchainDetector.
final class WorkshopLocalToolchainCatalogEntry {
  const WorkshopLocalToolchainCatalogEntry({
    required this.id,
    required this.name,
    required this.description,
    required this.requirement,
    required this.platforms,
    required this.relativePath,
  });

  final String id;
  final String name;
  final String description;
  final WorkshopToolchainRequirement requirement;
  final List<WorkshopToolchainPlatform> platforms;
  final String relativePath;

  bool supports(WorkshopToolchainPlatform platform) {
    return platforms.contains(platform);
  }

  bool get isRequired =>
      requirement == WorkshopToolchainRequirement.required;

  /// Trasforma la definizione statica in un componente realmente
  /// scaricabile dal WorkshopLocalToolchainManager.
  ///
  /// URL, dimensione e hash vengono forniti dal livello di
  /// configurazione/versioning e NON vengono inventati dal catalogo.
  WorkshopToolchainComponent toComponent({
    required String version,
    required String url,
    required int expectedBytes,
    String? sha256,
  }) {
    return WorkshopToolchainComponent(
      id: id,
      name: name,
      version: version,
      url: url,
      relativePath: relativePath,
      expectedBytes: expectedBytes,
      sha256: sha256,
      description: description,
    );
  }
}

/// Catalogo ufficiale della toolchain locale del Cantiere.
///
/// Ordine concettuale:
///
/// Flutter SDK
///   ↓
/// Dart SDK
///   ↓
/// JDK
///   ↓
/// Android SDK
///   ↓
/// Android Platform
///   ↓
/// Android Build Tools
///   ↓
/// Gradle
///
/// In futuro potranno essere aggiunti:
///
/// - CMake
/// - Ninja
/// - NDK
/// - LLVM/Clang
/// - toolchain Linux
/// - toolchain Windows
/// - toolchain macOS
/// - toolchain iOS
/// - toolchain per Arduino/ESP
/// - toolchain per altri laboratori hardware.
///
/// Il catalogo non presume che questi componenti siano presenti
/// sul telefono.
final class WorkshopLocalToolchainCatalog {
  WorkshopLocalToolchainCatalog._();

  static const List<WorkshopLocalToolchainCatalogEntry> entries =
      <WorkshopLocalToolchainCatalogEntry>[
    WorkshopLocalToolchainCatalogEntry(
      id: 'flutter_sdk',
      name: 'Flutter SDK',
      description:
          'SDK principale utilizzato per analizzare, generare e compilare '
          'progetti Flutter.',
      requirement: WorkshopToolchainRequirement.required,
      platforms: <WorkshopToolchainPlatform>[
        WorkshopToolchainPlatform.android,
        WorkshopToolchainPlatform.windows,
        WorkshopToolchainPlatform.linux,
        WorkshopToolchainPlatform.macos,
        WorkshopToolchainPlatform.ios,
      ],
      relativePath: 'flutter',
    ),

    WorkshopLocalToolchainCatalogEntry(
      id: 'dart_sdk',
      name: 'Dart SDK',
      description:
          'SDK Dart utilizzato dal Flutter SDK e dagli strumenti del '
          'Cantiere per analisi e automazione.',
      requirement: WorkshopToolchainRequirement.required,
      platforms: <WorkshopToolchainPlatform>[
        WorkshopToolchainPlatform.android,
        WorkshopToolchainPlatform.windows,
        WorkshopToolchainPlatform.linux,
        WorkshopToolchainPlatform.macos,
        WorkshopToolchainPlatform.ios,
      ],
      relativePath: 'dart',
    ),

    WorkshopLocalToolchainCatalogEntry(
      id: 'java_jdk',
      name: 'Java JDK',
      description:
          'JDK necessario per la toolchain Android e per gli strumenti '
          'Java utilizzati durante le build.',
      requirement: WorkshopToolchainRequirement.required,
      platforms: <WorkshopToolchainPlatform>[
        WorkshopToolchainPlatform.android,
        WorkshopToolchainPlatform.windows,
        WorkshopToolchainPlatform.linux,
        WorkshopToolchainPlatform.macos,
      ],
      relativePath: 'java',
    ),

    WorkshopLocalToolchainCatalogEntry(
      id: 'android_sdk',
      name: 'Android SDK',
      description:
          'SDK Android contenente gli strumenti necessari alla preparazione '
          'e compilazione degli artefatti Android.',
      requirement: WorkshopToolchainRequirement.required,
      platforms: <WorkshopToolchainPlatform>[
        WorkshopToolchainPlatform.android,
        WorkshopToolchainPlatform.windows,
        WorkshopToolchainPlatform.linux,
        WorkshopToolchainPlatform.macos,
      ],
      relativePath: 'android-sdk',
    ),

    WorkshopLocalToolchainCatalogEntry(
      id: 'android_platform',
      name: 'Android Platform',
      description:
          'Platform SDK Android specifica richiesta dal progetto in fase '
          'di compilazione.',
      requirement: WorkshopToolchainRequirement.required,
      platforms: <WorkshopToolchainPlatform>[
        WorkshopToolchainPlatform.android,
        WorkshopToolchainPlatform.windows,
        WorkshopToolchainPlatform.linux,
        WorkshopToolchainPlatform.macos,
      ],
      relativePath: 'android-sdk/platform',
    ),

    WorkshopLocalToolchainCatalogEntry(
      id: 'android_build_tools',
      name: 'Android Build Tools',
      description:
          'Strumenti Android utilizzati durante packaging, linking e '
          "generazione dell'APK/AAB.",
      requirement: WorkshopToolchainRequirement.required,
      platforms: <WorkshopToolchainPlatform>[
        WorkshopToolchainPlatform.android,
        WorkshopToolchainPlatform.windows,
        WorkshopToolchainPlatform.linux,
        WorkshopToolchainPlatform.macos,
      ],
      relativePath: 'android-sdk/build-tools',
    ),

    WorkshopLocalToolchainCatalogEntry(
      id: 'gradle',
      name: 'Gradle',
      description:
          'Build system utilizzato dal progetto Android generato da Flutter.',
      requirement: WorkshopToolchainRequirement.required,
      platforms: <WorkshopToolchainPlatform>[
        WorkshopToolchainPlatform.android,
        WorkshopToolchainPlatform.windows,
        WorkshopToolchainPlatform.linux,
        WorkshopToolchainPlatform.macos,
      ],
      relativePath: 'gradle',
    ),

    WorkshopLocalToolchainCatalogEntry(
      id: 'android_ndk',
      name: 'Android NDK',
      description:
          'Native Development Kit necessario quando il progetto utilizza '
          'componenti C/C++ o librerie native.',
      requirement: WorkshopToolchainRequirement.optional,
      platforms: <WorkshopToolchainPlatform>[
        WorkshopToolchainPlatform.android,
        WorkshopToolchainPlatform.windows,
        WorkshopToolchainPlatform.linux,
        WorkshopToolchainPlatform.macos,
      ],
      relativePath: 'android-sdk/ndk',
    ),

    WorkshopLocalToolchainCatalogEntry(
      id: 'cmake',
      name: 'CMake',
      description:
          'Sistema di configurazione e generazione per componenti native '
          'C/C++.',
      requirement: WorkshopToolchainRequirement.optional,
      platforms: <WorkshopToolchainPlatform>[
        WorkshopToolchainPlatform.android,
        WorkshopToolchainPlatform.windows,
        WorkshopToolchainPlatform.linux,
        WorkshopToolchainPlatform.macos,
      ],
      relativePath: 'cmake',
    ),

    WorkshopLocalToolchainCatalogEntry(
      id: 'ninja',
      name: 'Ninja',
      description:
          'Build tool veloce utilizzato da numerose toolchain native.',
      requirement: WorkshopToolchainRequirement.optional,
      platforms: <WorkshopToolchainPlatform>[
        WorkshopToolchainPlatform.android,
        WorkshopToolchainPlatform.windows,
        WorkshopToolchainPlatform.linux,
        WorkshopToolchainPlatform.macos,
      ],
      relativePath: 'ninja',
    ),
  ];

  static List<WorkshopLocalToolchainCatalogEntry> forPlatform(
    WorkshopToolchainPlatform platform,
  ) {
    return List.unmodifiable(
      entries.where(
        (entry) => entry.supports(platform),
      ),
    );
  }

  static List<WorkshopLocalToolchainCatalogEntry> requiredFor(
    WorkshopToolchainPlatform platform,
  ) {
    return List.unmodifiable(
      forPlatform(platform).where(
        (entry) => entry.isRequired,
      ),
    );
  }

  static List<WorkshopLocalToolchainCatalogEntry> optionalFor(
    WorkshopToolchainPlatform platform,
  ) {
    return List.unmodifiable(
      forPlatform(platform).where(
        (entry) =>
            entry.requirement ==
            WorkshopToolchainRequirement.optional,
      ),
    );
  }

  static WorkshopLocalToolchainCatalogEntry? find(
    String id,
  ) {
    for (final entry in entries) {
      if (entry.id == id) {
        return entry;
      }
    }

    return null;
  }

  static bool contains(String id) {
    return find(id) != null;
  }

  static List<String> idsFor(
    WorkshopToolchainPlatform platform,
  ) {
    return List.unmodifiable(
      forPlatform(platform).map(
        (entry) => entry.id,
      ),
    );
  }

  /// Restituisce gli ID dei componenti indispensabili.
  static List<String> requiredIdsFor(
    WorkshopToolchainPlatform platform,
  ) {
    return List.unmodifiable(
      requiredFor(platform).map(
        (entry) => entry.id,
      ),
    );
  }
}
