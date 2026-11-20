import 'dart:math' as math;

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_language.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_preview_frame.dart';
import 'package:flutter/material.dart';

/// Web-only presentation around the existing generation / verification flow.
///
/// This does not create a second generator, store credentials or pretend that a
/// live preview exists before the existing verified-preview API enables one.
class WorkshopWebGeneratorWorkspace extends StatefulWidget {
  const WorkshopWebGeneratorWorkspace({
    super.key,
    required this.composer,
    this.previewUri,
    this.projectTitle,
    this.generationStatus,
    this.verificationStatus,
    this.onOpenPreview,
    this.onOpenSources,
  });

  final Widget composer;
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
  bool _mobileViewport = true;
  bool _compactPreview = false;

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
    },
  };

  String _t(String italian) {
    final language = WorkshopWebLanguageScope.maybeOf(context)?.code;
    return _translations[language]?[italian] ?? italian;
  }

  @override
  Widget build(BuildContext context) {
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
                          '• $label',
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text(_t('Telefono')),
                  avatar: const Icon(Icons.smartphone, size: 18),
                  selected: _mobileViewport,
                  onSelected: (_) => setState(() => _mobileViewport = true),
                ),
                ChoiceChip(
                  label: Text(_t('Desktop')),
                  avatar: const Icon(Icons.desktop_windows_outlined, size: 18),
                  selected: !_mobileViewport,
                  onSelected: (_) => setState(() => _mobileViewport = false),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, size) {
                final maxWidth = math.max(180.0, size.maxWidth - 28);
                final width = _mobileViewport
                    ? math.min(382.0, maxWidth)
                    : maxWidth;
                final height = math.max(180.0, size.maxHeight - 28);
                return Center(
                  child: Container(
                    width: width,
                    height: height,
                    padding: EdgeInsets.all(_mobileViewport ? 9 : 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF232831),
                      borderRadius: BorderRadius.circular(
                          _mobileViewport ? 30 : 14),
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
                      borderRadius: BorderRadius.circular(
                          _mobileViewport ? 22 : 10),
                      child: previewReady
                          ? WorkshopWebPreviewFrame(uri: widget.previewUri!)
                          : _emptyPreview(),
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
                '• $label',
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
