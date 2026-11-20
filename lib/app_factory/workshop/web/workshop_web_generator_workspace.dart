import 'dart:math' as math;

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_language.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_preview_frame.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_platform_picker.dart';
import 'package:flutter/material.dart';

/// Web-only presentation around the existing generation / verification flow.
///
/// This does not create a second generator, store credentials or pretend that a
/// live preview exists before the existing verified-preview API enables one.
class WorkshopWebGeneratorWorkspace extends StatefulWidget {
  const WorkshopWebGeneratorWorkspace({
    super.key,
    required this.composer,
    this.intro,
    this.showIntro = false,
    this.platform,
    this.onPlatformChanged,
    this.previewUri,
    this.projectTitle,
    this.generationStatus,
    this.verificationStatus,
    this.onOpenPreview,
    this.onOpenSources,
  });

  final Widget composer;
  final Widget? intro;
  final bool showIntro;
  final WorkshopWebTarget? platform;
  final ValueChanged<WorkshopWebTarget>? onPlatformChanged;
  final Uri? previewUri;
  final String? projectTitle;
  final String? generationStatus;
  final String? verificationStatus;
  final VoidCallback? onOpenPreview;
  final VoidCallback? onOpenSources;

  @override
  State<WorkshopWebGeneratorWorkspace> createState() =>
      _WorkshopWebGeneratorWorkspaceState();
}

class _WorkshopWebGeneratorWorkspaceState
    extends State<WorkshopWebGeneratorWorkspace> {
  WorkshopWebTarget _fallbackPlatform = WorkshopWebTarget.web;
  bool _compactPreview = false;

  WorkshopWebTarget get _currentPlatform => widget.platform ?? _fallbackPlatform;

  void _selectPlatform(WorkshopWebTarget target) {
    widget.onPlatformChanged?.call(target);
    if (widget.platform == null) setState(() => _fallbackPlatform = target);
  }

  static const _translations = <String, Map<String, String>>{
    'en': {
      'Spazio di lavoro': 'Workspace',
      'Nuova applicazione': 'New application',
      'Descrivi la tua app e segui la creazione.': 'Describe your app and follow its creation.',
      'Richiesta': 'Request',
      'Anteprima interattiva': 'Interactive preview',
      'Telefono': 'Phone',
      'Desktop': 'Desktop',
      'Apri a tutto schermo': 'Open full screen',
      'Apri sorgenti': 'Open source files',
      'Nessuna app da visualizzare': 'No app to display yet',
      'L’anteprima sarà utilizzabile dopo la generazione e la verifica.':
          'The preview will be usable after generation and verification.',
      'Anteprima verificata': 'Verified preview',
      'In attesa di un’app verificata': 'Waiting for a verified app',
      'La cornice cambia; l’app eseguita resta Web.':
          'The frame changes; the running app is still Web.',
    },
    'fr': {
      'Spazio di lavoro': 'Espace de travail',
      'Nuova applicazione': 'Nouvelle application',
      'Descrivi la tua app e segui la creazione.':
          'Décrivez votre application et suivez sa création.',
      'Richiesta': 'Demande',
      'Anteprima interattiva': 'Aperçu interactif',
      'Telefono': 'Téléphone',
      'Desktop': 'Bureau',
      'Apri a tutto schermo': 'Ouvrir en plein écran',
      'Apri sorgenti': 'Afficher les sources',
      'Nessuna app da visualizzare': 'Aucune application à afficher',
      'L’anteprima sarà utilizzabile dopo la generazione e la verifica.':
          'L’aperçu sera utilisable après la génération et la vérification.',
      'Anteprima verificata': 'Aperçu vérifié',
      'In attesa di un’app verificata': 'En attente d’une application vérifiée',
      'La cornice cambia; l’app eseguita resta Web.':
          'Le cadre change ; l’application reste Web.',
    },
    'es': {
      'Spazio di lavoro': 'Espacio de trabajo',
      'Nuova applicazione': 'Nueva aplicación',
      'Descrivi la tua app e segui la creazione.':
          'Describe tu aplicación y sigue su creación.',
      'Richiesta': 'Solicitud',
      'Anteprima interattiva': 'Vista previa interactiva',
      'Telefono': 'Teléfono',
      'Desktop': 'Escritorio',
      'Apri a tutto schermo': 'Abrir a pantalla completa',
      'Apri sorgenti': 'Abrir código fuente',
      'Nessuna app da visualizzare': 'Todavía no hay ninguna aplicación',
      'L’anteprima sarà utilizzabile dopo la generazione e la verifica.':
          'La vista previa estará disponible tras la generación y verificación.',
      'Anteprima verificata': 'Vista previa verificada',
      'In attesa di un’app verificata': 'Esperando una aplicación verificada',
      'La cornice cambia; l’app eseguita resta Web.':
          'El marco cambia; la aplicación sigue siendo Web.',
    },
  };

  String _t(String italian) {
    final language = WorkshopWebLanguageScope.maybeOf(context)?.code;
    return _translations[language]?[italian] ?? italian;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.showIntro) {
      return ColoredBox(
        color: const Color(0xFF0B0E13),
        child: widget.intro ?? widget.composer,
      );
    }
    return LayoutBuilder(
      builder: (context, size) {
        if (size.maxWidth >= 900) {
          return Row(
            children: [
              SizedBox(
                width: math.min(470, size.maxWidth * 0.42),
                child: _requestPane(),
              ),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(child: _previewPane()),
            ],
          );
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: false,
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: Text(_t('Richiesta')),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: const Icon(Icons.smartphone_outlined),
                    label: Text(_t('Anteprima interattiva')),
                  ),
                ],
                selected: {_compactPreview},
                onSelectionChanged: (value) =>
                    setState(() => _compactPreview = value.first),
              ),
            ),
            Expanded(
              child: _compactPreview ? _previewPane() : _requestPane(),
            ),
          ],
        );
      },
    );
  }

  Widget _requestPane() {
    return ColoredBox(
      color: const Color(0xFF11151B),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _t('Spazio di lavoro').toUpperCase(),
                  style: const TextStyle(
                    color: Color(0xFF86BBFA),
                    fontSize: 11,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.projectTitle == null
                      ? _t('Nuova applicazione')
                      : 'Progetto · ${widget.projectTitle}',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  _t('Descrivi la tua app e segui la creazione.'),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.66)),
                ),
                if (widget.generationStatus case final label?) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.auto_awesome, size: 16, color: Color(0xFF86BBFA)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          label,
                          style: const TextStyle(color: Color(0xFF9CC7F6)),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: widget.composer),
        ],
      ),
    );
  }

  Widget _previewPane() {
    final previewReady = widget.previewUri != null;
    return ColoredBox(
      color: const Color(0xFF0B0E13),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
            child: Row(
              children: [
                const Icon(Icons.visibility_outlined, size: 21),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _t('Anteprima interattiva'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        _t(previewReady
                            ? 'Anteprima verificata'
                            : 'In attesa di un’app verificata'),
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.58),
                        ),
                      ),
                    ],
                  ),
                ),
                if (previewReady) ...[
                  IconButton(
                    tooltip: _t('Apri sorgenti'),
                    onPressed: widget.onOpenSources,
                    icon: const Icon(Icons.code),
                  ),
                  IconButton(
                    tooltip: _t('Apri a tutto schermo'),
                    onPressed: widget.onOpenPreview,
                    icon: const Icon(Icons.open_in_full),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                WorkshopWebPlatformPicker(
                  selected: _currentPlatform,
                  onChanged: _selectPlatform,
                ),
                const SizedBox(height: 6),
                Text(
                  _t('La cornice cambia; l’app eseguita resta Web.'),
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, size) {
                final target = _currentPlatform;
                final isPhone = target.isPhone;
                final availableWidth = math.max(180.0, size.maxWidth - 28);
                final availableHeight = math.max(180.0, size.maxHeight - 28);
                final width = isPhone
                    ? math.min(
                        target == WorkshopWebTarget.ios ? 390.0 : 375.0,
                        math.min(availableWidth, availableHeight / 1.8),
                      )
                    : availableWidth;
                final height = isPhone
                    ? math.min(availableHeight, width * 1.96)
                    : availableHeight;
                return Center(
                  child: Container(
                    key: Key('web_preview_platform_' + target.name),
                    width: width,
                    height: height,
                    padding: EdgeInsets.all(isPhone ? 8 : 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF232831),
                      borderRadius: BorderRadius.circular(isPhone ? 34 : 14),
                      border: Border.all(
                        color: const Color(0xFF414956),
                        width: 2,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          blurRadius: 28,
                          color: Color(0x80000000),
                          offset: Offset(0, 12),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(isPhone ? 27 : 10),
                      child: Column(
                        children: [
                          _platformChrome(target),
                          Expanded(
                            child: previewReady
                                ? WorkshopWebPreviewFrame(uri: widget.previewUri!)
                                : _emptyPreview(),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (widget.verificationStatus case final label?)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Decorative device/window chrome only. All app taps and navigation happen
  /// inside the sandboxed, interactive Web iframe below this header.
  Widget _platformChrome(WorkshopWebTarget target) {
    if (target.isPhone) {
      return SizedBox(
        height: 27,
        child: ColoredBox(
          color: const Color(0xFF192331),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (target == WorkshopWebTarget.ios)
                Container(
                  width: 72,
                  height: 15,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(12),
                  ),
                )
              else ...[
                const Icon(Icons.circle, size: 7, color: Colors.white54),
                const SizedBox(width: 7),
                const Icon(Icons.wifi, size: 13, color: Colors.white70),
                const SizedBox(width: 7),
                const Icon(Icons.battery_full, size: 14, color: Colors.white70),
              ],
            ],
          ),
        ),
      );
    }

    return Container(
      height: 34,
      color: const Color(0xFF202A37),
      child: Row(
        children: [
          const SizedBox(width: 12),
          if (target == WorkshopWebTarget.macos) ...[
            for (final color in [
              const Color(0xFFFF6258),
              const Color(0xFFFFBE2F),
              const Color(0xFF28C840),
            ]) ...[
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
            ],
          ] else
            Icon(target.icon, size: 17, color: const Color(0xFFD6E6FB)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'AIVEXUS · ' + target.label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyPreview() {
    return ColoredBox(
      color: const Color(0xFF151B24),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.widgets_outlined,
                color: Color(0xFF91BDF1),
                size: 52,
              ),
              const SizedBox(height: 18),
              Text(
                _t('Nessuna app da visualizzare'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              Text(
                _t('L’anteprima sarà utilizzabile dopo la generazione e la verifica.'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
