import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Componente scaricabile della toolchain locale.
///
/// Il manager non decide quale toolchain usare e non esegue build.
/// Gestisce solamente il ciclo di vita dei file della toolchain.
final class WorkshopToolchainComponent {
  const WorkshopToolchainComponent({
    required this.id,
    required this.name,
    required this.version,
    required this.url,
    required this.relativePath,
    required this.expectedBytes,
    this.sha256,
    this.description,
  });

  final String id;
  final String name;
  final String version;

  /// URL ufficiale del componente.
  final String url;

  /// Percorso relativo alla directory persistente.
  final String relativePath;

  /// Dimensione attesa in byte.
  ///
  /// Se <= 0, la dimensione non viene verificata.
  final int expectedBytes;

  /// SHA-256 atteso.
  ///
  /// Se presente, viene verificato dopo il download.
  final String? sha256;

  final String? description;
}

/// Stato del componente locale.
enum WorkshopToolchainComponentState {
  notInstalled,
  partial,
  downloading,
  installed,
  invalid,
}

/// Snapshot dello stato di un componente.
final class WorkshopToolchainComponentStatus {
  const WorkshopToolchainComponentStatus({
    required this.component,
    required this.state,
    required this.path,
    required this.partialPath,
    required this.downloadedBytes,
    required this.expectedBytes,
    required this.valid,
    this.error,
  });

  final WorkshopToolchainComponent component;
  final WorkshopToolchainComponentState state;

  final String path;
  final String partialPath;

  final int downloadedBytes;
  final int expectedBytes;

  final bool valid;
  final String? error;

  double get progress {
    if (expectedBytes <= 0) {
      return 0;
    }

    final value =
        downloadedBytes / expectedBytes;

    if (value < 0) {
      return 0;
    }

    if (value > 1) {
      return 1;
    }

    return value;
  }

  bool get isInstalled =>
      state ==
          WorkshopToolchainComponentState.installed &&
      valid;
}

/// Configurazione dello storage locale.
final class WorkshopLocalToolchainManagerConfiguration {
  const WorkshopLocalToolchainManagerConfiguration({
    this.directoryName = 'workshop_toolchain',
    this.partialDirectoryName = '.partial',
    this.manifestFileName = 'manifest.json',
    this.timeout = const Duration(minutes: 30),
    this.maxRedirects = 5,
  });

  final String directoryName;
  final String partialDirectoryName;
  final String manifestFileName;

  final Duration timeout;
  final int maxRedirects;
}

/// Manifest persistente della toolchain.
final class WorkshopToolchainManifest {
  const WorkshopToolchainManifest({
    required this.version,
    required this.updatedAt,
    required this.components,
  });

  final int version;
  final DateTime updatedAt;
  final List<WorkshopToolchainManifestEntry> components;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'version': version,
      'updatedAt':
          updatedAt.toUtc().toIso8601String(),
      'components':
          components
              .map(
                (entry) => entry.toJson(),
              )
              .toList(growable: false),
    };
  }

  factory WorkshopToolchainManifest.fromJson(
    Map<String, dynamic> json,
  ) {
    final raw =
        json['components'];

    final entries =
        <WorkshopToolchainManifestEntry>[];

    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          entries.add(
            WorkshopToolchainManifestEntry.fromJson(
              Map<String, dynamic>.from(item),
            ),
          );
        }
      }
    }

    return WorkshopToolchainManifest(
      version:
          json['version'] is int
              ? json['version'] as int
              : 1,
      updatedAt:
          DateTime.tryParse(
                json['updatedAt']?.toString() ?? '',
              ) ??
              DateTime.fromMillisecondsSinceEpoch(
                0,
                isUtc: true,
              ),
      components:
          List.unmodifiable(entries),
    );
  }
}

/// Voce persistente relativa a un componente installato.
final class WorkshopToolchainManifestEntry {
  const WorkshopToolchainManifestEntry({
    required this.id,
    required this.version,
    required this.bytes,
    required this.sha256,
    required this.installedAt,
  });

  final String id;
  final String version;
  final int bytes;
  final String sha256;
  final DateTime installedAt;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'version': version,
      'bytes': bytes,
      'sha256': sha256,
      'installedAt':
          installedAt.toUtc().toIso8601String(),
    };
  }

  factory WorkshopToolchainManifestEntry.fromJson(
    Map<String, dynamic> json,
  ) {
    return WorkshopToolchainManifestEntry(
      id: json['id']?.toString() ?? '',
      version:
          json['version']?.toString() ?? '',
      bytes:
          json['bytes'] is num
              ? (json['bytes'] as num).toInt()
              : 0,
      sha256:
          json['sha256']?.toString() ?? '',
      installedAt:
          DateTime.tryParse(
                json['installedAt']?.toString() ?? '',
              ) ??
              DateTime.fromMillisecondsSinceEpoch(
                0,
                isUtc: true,
              ),
    );
  }
}

/// Storage/download manager della toolchain locale.
///
/// RESPONSABILITÀ:
/// - directory persistente;
/// - file .part;
/// - resume HTTP;
/// - validazione dimensione;
/// - validazione SHA-256;
/// - manifest;
/// - cancellazione;
/// - rimozione.
///
/// NON RESPONSABILITÀ:
/// - scegliere Local/Remote;
/// - decidere il target;
/// - eseguire Flutter;
/// - eseguire build;
/// - gestire il LLM;
/// - modificare il repository reale.
final class WorkshopLocalToolchainManager {
  WorkshopLocalToolchainManager({
    WorkshopLocalToolchainManagerConfiguration
        configuration =
        const WorkshopLocalToolchainManagerConfiguration(),
  }) : _configuration = configuration;

  final WorkshopLocalToolchainManagerConfiguration
      _configuration;

  Directory? _root;
  Directory? _partialRoot;

  final Map<String, HttpClient> _clients =
      <String, HttpClient>{};

  final Set<String> _cancelled =
      <String>{};

  bool _initialized = false;
  bool _disposed = false;

  /// Inizializza lo storage persistente.
  Future<Directory> initialize() async {
    _ensureAvailable();

    if (_initialized && _root != null) {
      return _root!;
    }

    final supportDirectory =
        await getApplicationSupportDirectory();

    final root = Directory(
      p.join(
        supportDirectory.path,
        _configuration.directoryName,
      ),
    );

    final partialRoot = Directory(
      p.join(
        root.path,
        _configuration.partialDirectoryName,
      ),
    );

    await root.create(recursive: true);
    await partialRoot.create(recursive: true);

    _root = root;
    _partialRoot = partialRoot;
    _initialized = true;

    return root;
  }

  Future<Directory> get rootDirectory =>
      initialize();

  /// Controlla lo stato attuale senza modificare nulla.
  Future<WorkshopToolchainComponentStatus> inspect(
    WorkshopToolchainComponent component,
  ) async {
    _ensureAvailable();

    final root =
        await initialize();

    final destination =
        File(
          p.join(
            root.path,
            component.relativePath,
          ),
        );

    final partial =
        await _partialFile(component);

    if (await destination.exists()) {
      final valid =
          await _validate(
            component,
            destination,
          );

      return WorkshopToolchainComponentStatus(
        component: component,
        state:
            valid
                ? WorkshopToolchainComponentState
                    .installed
                : WorkshopToolchainComponentState
                    .invalid,
        path: destination.path,
        partialPath: partial.path,
        downloadedBytes:
            await _length(destination),
        expectedBytes:
            component.expectedBytes,
        valid: valid,
        error:
            valid
                ? null
                : 'Installed component failed validation.',
      );
    }

    final partialBytes =
        await _length(partial);

    return WorkshopToolchainComponentStatus(
      component: component,
      state:
          partialBytes > 0
              ? WorkshopToolchainComponentState.partial
              : WorkshopToolchainComponentState.notInstalled,
      path: destination.path,
      partialPath: partial.path,
      downloadedBytes: partialBytes,
      expectedBytes:
          component.expectedBytes,
      valid: false,
    );
  }

  /// Scarica/installare un componente.
  ///
  /// Se esiste un `.part`, il download tenta automaticamente
  /// di riprendere dal byte già presente.
  Future<WorkshopToolchainComponentStatus> download(
    WorkshopToolchainComponent component, {
    void Function(
      int received,
      int total,
    )? onProgress,
  }) async {
    _ensureAvailable();

    final current =
        await inspect(component);

    if (current.isInstalled) {
      return current;
    }

    final root =
        await initialize();

    final destination =
        File(
          p.join(
            root.path,
            component.relativePath,
          ),
        );

    final partial =
        await _partialFile(component);

    await destination.parent.create(
      recursive: true,
    );

    await partial.parent.create(
      recursive: true,
    );

    _cancelled.remove(component.id);

    try {
      await _downloadToPartial(
        component,
        partial,
        onProgress: onProgress,
      );

      if (_cancelled.contains(component.id)) {
        return inspect(component);
      }

      final valid =
          await _validate(
            component,
            partial,
          );

      if (!valid) {
        return WorkshopToolchainComponentStatus(
          component: component,
          state:
              WorkshopToolchainComponentState.invalid,
          path: destination.path,
          partialPath: partial.path,
          downloadedBytes:
              await _length(partial),
          expectedBytes:
              component.expectedBytes,
          valid: false,
          error:
              'Downloaded component failed validation.',
        );
      }

      if (await destination.exists()) {
        await destination.delete();
      }

      await partial.rename(
        destination.path,
      );

      final hash =
          await _sha256(destination);

      await _updateManifest(
        WorkshopToolchainManifestEntry(
          id: component.id,
          version: component.version,
          bytes:
              await _length(destination),
          sha256: hash,
          installedAt:
              DateTime.now().toUtc(),
        ),
      );

      return WorkshopToolchainComponentStatus(
        component: component,
        state:
            WorkshopToolchainComponentState
                .installed,
        path: destination.path,
        partialPath: partial.path,
        downloadedBytes:
            await _length(destination),
        expectedBytes:
            component.expectedBytes,
        valid: true,
      );
    } catch (error) {
      return WorkshopToolchainComponentStatus(
        component: component,
        state:
            WorkshopToolchainComponentState
                .invalid,
        path: destination.path,
        partialPath: partial.path,
        downloadedBytes:
            await _length(partial),
        expectedBytes:
            component.expectedBytes,
        valid: false,
        error: error.toString(),
      );
    }
  }

  /// Alias esplicito per il codice del Cantiere.
  Future<WorkshopToolchainComponentStatus> install(
    WorkshopToolchainComponent component, {
    void Function(
      int received,
      int total,
    )? onProgress,
  }) {
    return download(
      component,
      onProgress: onProgress,
    );
  }

  /// Cancella il download mantenendo il `.part`.
  ///
  /// La prossima chiamata a download() tenterà il resume.
  Future<void> cancel(
    WorkshopToolchainComponent component,
  ) async {
    _ensureAvailable();

    _cancelled.add(component.id);

    final client =
        _clients.remove(component.id);

    client?.close(force: true);
  }

  /// Rimuove completamente il componente.
  Future<void> remove(
    WorkshopToolchainComponent component,
  ) async {
    _ensureAvailable();

    final root =
        await initialize();

    final destination =
        File(
          p.join(
            root.path,
            component.relativePath,
          ),
        );

    final partial =
        await _partialFile(component);

    if (await destination.exists()) {
      await destination.delete();
    }

    if (await partial.exists()) {
      await partial.delete();
    }

    await _removeManifestEntry(
      component.id,
    );
  }

  /// Legge il manifest persistente.
  Future<WorkshopToolchainManifest>
      readManifest() async {
    _ensureAvailable();

    final root =
        await initialize();

    final file =
        File(
          p.join(
            root.path,
            _configuration.manifestFileName,
          ),
        );

    if (!await file.exists()) {
      return WorkshopToolchainManifest(
        version: 1,
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(
          0,
          isUtc: true,
        ),
        components:
            const <WorkshopToolchainManifestEntry>[],
      );
    }

    try {
      final content =
          await file.readAsString();

      final decoded =
          jsonDecode(content);

      if (decoded is Map) {
        return WorkshopToolchainManifest.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      }
    } catch (_) {
      // Manifest corrotto:
      // ricostruiamo uno stato vuoto senza crash.
    }

    return WorkshopToolchainManifest(
      version: 1,
      updatedAt:
          DateTime.fromMillisecondsSinceEpoch(
        0,
        isUtc: true,
      ),
      components:
          const <WorkshopToolchainManifestEntry>[],
    );
  }

  Future<void> _downloadToPartial(
    WorkshopToolchainComponent component,
    File partial, {
    void Function(
      int received,
      int total,
    )? onProgress,
  }) async {
    final uri =
        Uri.tryParse(component.url);

    if (uri == null ||
        uri.scheme.isEmpty ||
        uri.host.isEmpty) {
      throw const FormatException(
        'Invalid toolchain URL.',
      );
    }

    var existingBytes =
        await _length(partial);

    var currentUri = uri;
    var redirects = 0;
    var retriedFromZero = false;

    final client = HttpClient();

    _clients[component.id] = client;

    try {
      client.connectionTimeout =
          _configuration.timeout;

      while (true) {
        final request =
            await client.getUrl(currentUri);

        request.followRedirects = false;

        request.headers.set(
          HttpHeaders.acceptHeader,
          '*/*',
        );

        if (existingBytes > 0) {
          request.headers.set(
            HttpHeaders.rangeHeader,
            'bytes=$existingBytes-',
          );
        }

        final response =
            await request.close().timeout(
          _configuration.timeout,
        );

        if (_isRedirect(
          response.statusCode,
        )) {
          final location =
              response.headers.value(
            HttpHeaders.locationHeader,
          );

          if (location == null) {
            throw const HttpException(
              'Redirect without Location header.',
            );
          }

          redirects++;

          if (redirects >
              _configuration.maxRedirects) {
            throw const HttpException(
              'Too many HTTP redirects.',
            );
          }

          currentUri =
              currentUri.resolve(location);

          continue;
        }

        if (response.statusCode ==
                HttpStatus.requestedRangeNotSatisfiable &&
            existingBytes > 0 &&
            !retriedFromZero) {
          existingBytes = 0;
          retriedFromZero = true;

          if (await partial.exists()) {
            await partial.delete();
          }

          continue;
        }

        if (response.statusCode !=
                HttpStatus.ok &&
            response.statusCode !=
                HttpStatus.partialContent) {
          throw HttpException(
            'HTTP ${response.statusCode} '
            'while downloading ${component.name}.',
          );
        }

        final serverSupportsResume =
            response.statusCode ==
                HttpStatus.partialContent;

        final append =
            existingBytes > 0 &&
            serverSupportsResume;

        if (!append) {
          existingBytes = 0;

          if (await partial.exists()) {
            await partial.delete();
          }
        }

        final sink =
            partial.openWrite(
          mode:
              append
                  ? FileMode.append
                  : FileMode.write,
        );

        var received =
            existingBytes;

        try {
          await for (
            final chunk in response
          ) {
            if (_cancelled.contains(
              component.id,
            )) {
              return;
            }

            sink.add(chunk);

            received +=
                chunk.length;

            onProgress?.call(
              received,
              component.expectedBytes,
            );
          }
        } finally {
          await sink.flush();
          await sink.close();
        }

        return;
      }
    } finally {
      _clients.remove(component.id);
      client.close(force: true);
    }
  }

  Future<bool> _validate(
    WorkshopToolchainComponent component,
    File file,
  ) async {
    if (!await file.exists()) {
      return false;
    }

    final bytes =
        await _length(file);

    if (bytes <= 0) {
      return false;
    }

    if (component.expectedBytes > 0 &&
        bytes != component.expectedBytes) {
      return false;
    }

    final expectedHash =
        component.sha256?.trim();

    if (expectedHash == null ||
        expectedHash.isEmpty) {
      return true;
    }

    final actual =
        await _sha256(file);

    return actual.toLowerCase() ==
        expectedHash.toLowerCase();
  }

  Future<String> _sha256(
    File file,
  ) async {
    final digest =
        await sha256.bind(
      file.openRead(),
    ).first;

    return digest.toString();
  }

  Future<void> _updateManifest(
    WorkshopToolchainManifestEntry entry,
  ) async {
    final current =
        await readManifest();

    final entries =
        <WorkshopToolchainManifestEntry>[
      for (final existing
          in current.components)
        if (existing.id != entry.id)
          existing,
      entry,
    ];

    await _writeManifest(
      WorkshopToolchainManifest(
        version: 1,
        updatedAt:
            DateTime.now().toUtc(),
        components:
            List.unmodifiable(entries),
      ),
    );
  }

  Future<void> _removeManifestEntry(
    String id,
  ) async {
    final current =
        await readManifest();

    final entries =
        current.components
            .where(
              (entry) => entry.id != id,
            )
            .toList(growable: false);

    await _writeManifest(
      WorkshopToolchainManifest(
        version: current.version,
        updatedAt:
            DateTime.now().toUtc(),
        components:
            List.unmodifiable(entries),
      ),
    );
  }

  Future<void> _writeManifest(
    WorkshopToolchainManifest manifest,
  ) async {
    final root =
        await initialize();

    final file =
        File(
          p.join(
            root.path,
            _configuration.manifestFileName,
          ),
        );

    final json =
        const JsonEncoder.withIndent('  ')
            .convert(
              manifest.toJson(),
            );

    await file.writeAsString(
      json,
      flush: true,
    );
  }

  Future<File> _partialFile(
  WorkshopToolchainComponent component,
) async {
  if (_partialRoot == null) {
    await initialize();
  }

  final partialRoot = _partialRoot;

  if (partialRoot == null) {
    throw StateError(
      'Workshop toolchain partial directory could not be initialized.',
    );
  }

  final safeId = _safeFileName(
    '${component.id}-${component.version}',
  );

  return File(
    p.join(
      partialRoot.path,
      '$safeId.part',
    ),
  );
  }

  String _safeFileName(
    String value,
  ) {
    return value.replaceAll(
      RegExp(r'[^a-zA-Z0-9._-]'),
      '_',
    );
  }

  Future<int> _length(
    File file,
  ) async {
    try {
      if (!await file.exists()) {
        return 0;
      }

      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  bool _isRedirect(
    int statusCode,
  ) {
    return statusCode ==
            HttpStatus.movedPermanently ||
        statusCode == HttpStatus.found ||
        statusCode == HttpStatus.seeOther ||
        statusCode ==
            HttpStatus.temporaryRedirect ||
        statusCode == 308;
  }

  void _ensureAvailable() {
    if (_disposed) {
      throw StateError(
        'WorkshopLocalToolchainManager '
        'has been disposed.',
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }

    _disposed = true;

    for (final client
        in _clients.values) {
      client.close(force: true);
    }

    _clients.clear();
    _cancelled.clear();
  }
}
