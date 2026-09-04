import 'package:flutter/material.dart';

import 'workshop_model_assignments.dart';
import 'workshop_model_roles.dart';
import 'workshop_model_storage.dart';

/// Dedicated Workshop model configuration page.
///
/// The Assistant has a different model-selection UI and a different
/// persistence namespace.
///
/// Workshop:
///
///   Orchestrator → model
///   Architect    → model
///   Engineer     → model
///   Reviewer     → model
///
/// Selecting a model here never changes the Assistant selected model.
class WorkshopModelSelectionPage extends StatefulWidget {
  const WorkshopModelSelectionPage({
    super.key,
  });

  @override
  State<WorkshopModelSelectionPage> createState() =>
      _WorkshopModelSelectionPageState();
}

class _WorkshopModelSelectionPageState
    extends State<WorkshopModelSelectionPage> {
  final WorkshopModelStorage _storage =
      const WorkshopModelStorage();

  List<WorkshopModelAssignment> _assignments =
      WorkshopModelAssignments.defaults;

  final Map<String, bool> _availability =
      <String, bool>{};

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final assignments =
          await WorkshopModelAssignments.load();

      final states =
          await _storage.inspectAll();

      final availability =
          <String, bool>{};

      for (final state in states) {
        availability[state.model.id] =
            state.isReady;
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _assignments = assignments;
        _availability
          ..clear()
          ..addAll(availability);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _error =
            'Impossibile caricare la configurazione del Cantiere: '
            '$error';
      });
    }
  }

  WorkshopModelAssignment? _assignmentFor(
    AppAiRole role,
  ) {
    for (final assignment in _assignments) {
      if (assignment.role == role) {
        return assignment;
      }
    }

    return null;
  }

  WorkshopModelDescriptor? _modelForRole(
    AppAiRole role,
  ) {
    final assignment =
        _assignmentFor(role);

    if (assignment == null) {
      return null;
    }

    return WorkshopModelCatalogue.findById(
      assignment.modelId,
    );
  }

  Future<void> _selectModel(
    AppAiRole role,
  ) async {
    final candidates =
        WorkshopModelCatalogue.forRole(role);

    if (candidates.isEmpty) {
      _showMessage(
        'Nessun modello Workshop disponibile per ${role.label}.',
      );
      return;
    }

    final selected =
        await showModalBottomSheet<WorkshopModelDescriptor>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _WorkshopModelPickerSheet(
          role: role,
          candidates: candidates,
          selectedModelId:
              _assignmentFor(role)?.modelId,
          availability: _availability,
          onRefresh: _load,
        );
      },
    );

    if (selected == null) {
      return;
    }

    final next =
        WorkshopModelAssignments.withAssignment(
      _assignments,
      role,
      selected.id,
    );

    if (!WorkshopModelAssignments.isValid(next)) {
      _showMessage(
        WorkshopModelAssignments
            .validate(next)
            .join('\n'),
      );
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await WorkshopModelAssignments.save(
        next,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _assignments = next;
        _saving = false;
      });

      _showMessage(
        '${role.label}: ${selected.displayName}',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _saving = false;
        _error =
            'Impossibile salvare la scelta: $error';
      });
    }
  }

  Future<void> _resetToDefaults() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await WorkshopModelAssignments.save(
        WorkshopModelAssignments.defaults,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _assignments =
            WorkshopModelAssignments.defaults;
        _saving = false;
      });

      _showMessage(
        'Configurazione del Cantiere ripristinata.',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _saving = false;
        _error =
            'Impossibile ripristinare la configurazione: '
            '$error';
      });
    }
  }

  void _showMessage(
    String message,
  ) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior:
              SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Modelli AI del Cantiere',
        ),
        actions: [
          IconButton(
            tooltip: 'Aggiorna',
            onPressed:
                _loading ? null : _load,
            icon: const Icon(
              Icons.refresh,
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'reset') {
                _resetToDefaults();
              }
            },
            itemBuilder:
                (context) => const [
              PopupMenuItem<String>(
                value: 'reset',
                child: Text(
                  'Ripristina configurazione predefinita',
                ),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child:
                  CircularProgressIndicator(),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding:
                    const EdgeInsets.fromLTRB(
                  16,
                  16,
                  16,
                  32,
                ),
                children: [
                  _IntroCard(),
                  const SizedBox(
                    height: 16,
                  ),
                  for (final role
                      in const [
                    AppAiRole
                        .workshopOrchestrator,
                    AppAiRole.architect,
                    AppAiRole.engineer,
                    AppAiRole.reviewer,
                  ])
                    Padding(
                      padding:
                          const EdgeInsets.only(
                        bottom: 12,
                      ),
                      child:
                          _WorkshopRoleCard(
                        role: role,
                        model:
                            _modelForRole(
                          role,
                        ),
                        downloaded:
                            _modelForRole(role) ==
                                    null
                                ? false
                                : (_availability[
                                        _modelForRole(
                                                role)!
                                            .id] ??
                                    false),
                        busy: _saving,
                        onTap: () =>
                            _selectModel(
                          role,
                        ),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding:
                          const EdgeInsets.only(
                        top: 4,
                      ),
                      child:
                          Card(
                        child:
                            Padding(
                          padding:
                              const EdgeInsets.all(
                            16,
                          ),
                          child: Text(
                            _error!,
                            style:
                                TextStyle(
                              color:
                                  Theme.of(
                                context,
                              )
                                      .colorScheme
                                      .error,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard();

  @override
  Widget build(
    BuildContext context,
  ) {
    return Card(
      child: Padding(
        padding:
            const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.engineering_outlined,
                  color:
                      Theme.of(context)
                          .colorScheme
                          .primary,
                ),
                const SizedBox(
                  width: 10,
                ),
                const Expanded(
                  child: Text(
                    'Configurazione indipendente',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight:
                          FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(
              height: 10,
            ),
            Text(
              'Questi modelli appartengono al Cantiere. '
              'La selezione dell’Assistente non viene modificata.',
              style: TextStyle(
                color:
                    Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(
                          alpha: 0.70,
                        ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkshopRoleCard
    extends StatelessWidget {
  const _WorkshopRoleCard({
    required this.role,
    required this.model,
    required this.downloaded,
    required this.busy,
    required this.onTap,
  });

  final AppAiRole role;
  final WorkshopModelDescriptor? model;
  final bool downloaded;
  final bool busy;
  final VoidCallback onTap;

  IconData get _icon {
    switch (role) {
      case AppAiRole.workshopOrchestrator:
        return Icons.hub_outlined;
      case AppAiRole.architect:
        return Icons.architecture_outlined;
      case AppAiRole.engineer:
        return Icons.code_rounded;
      case AppAiRole.reviewer:
        return Icons.fact_check_outlined;
      case AppAiRole.assistantOrchestrator:
        return Icons.smart_toy_outlined;
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final colorScheme =
        Theme.of(context).colorScheme;

    return Card(
      clipBehavior:
          Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : onTap,
        child: Padding(
          padding:
              const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration:
                    BoxDecoration(
                  color:
                      colorScheme.primary
                          .withValues(
                    alpha: 0.12,
                  ),
                  borderRadius:
                      BorderRadius.circular(
                    12,
                  ),
                ),
                child: Icon(
                  _icon,
                  color:
                      colorScheme.primary,
                ),
              ),
              const SizedBox(
                width: 14,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      role.label
                          .replaceFirst(
                        'Cantiere / ',
                        '',
                      ),
                      style:
                          const TextStyle(
                        fontWeight:
                            FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(
                      height: 6,
                    ),
                    Text(
                      model?.displayName ??
                          'Nessun modello assegnato',
                      maxLines: 2,
                      overflow:
                          TextOverflow.ellipsis,
                      style:
                          const TextStyle(
                        fontSize: 14,
                      ),
                    ),
                    if (model != null) ...[
                      const SizedBox(
                        height: 5,
                      ),
                      Row(
                        children: [
                          Icon(
                            downloaded
                                ? Icons
                                    .check_circle_outline
                                : Icons
                                    .cloud_download_outlined,
                            size: 15,
                            color: downloaded
                                ? Colors.green
                                : colorScheme
                                    .onSurface
                                    .withValues(
                                    alpha:
                                        0.55,
                                  ),
                          ),
                          const SizedBox(
                            width: 5,
                          ),
                          Text(
                            downloaded
                                ? 'Scaricato'
                                : 'Non ancora scaricato',
                            style:
                                TextStyle(
                              fontSize: 11,
                              color: colorScheme
                                  .onSurface
                                  .withValues(
                                alpha:
                                    0.58,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(
                width: 8,
              ),
              const Icon(
                Icons
                    .chevron_right_rounded,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkshopModelPickerSheet
    extends StatelessWidget {
  const _WorkshopModelPickerSheet({
    required this.role,
    required this.candidates,
    required this.selectedModelId,
    required this.availability,
    required this.onRefresh,
  });

  final AppAiRole role;
  final List<WorkshopModelDescriptor>
      candidates;
  final String? selectedModelId;
  final Map<String, bool> availability;
  final Future<void> Function()
      onRefresh;

  @override
  Widget build(
    BuildContext context,
  ) {
    final mediaQuery =
        MediaQuery.of(context);

    return SafeArea(
      child: Container(
        constraints:
            BoxConstraints(
          maxHeight:
              mediaQuery.size.height *
                  0.84,
        ),
        decoration:
            BoxDecoration(
          color:
              Theme.of(context)
                  .colorScheme
                  .surface,
          borderRadius:
              const BorderRadius.vertical(
            top: Radius.circular(24),
          ),
        ),
        child: Column(
          children: [
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(
                20,
                18,
                12,
                10,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment
                              .start,
                      children: [
                        Text(
                          'Modello per ${_shortRoleName(role)}',
                          style:
                              const TextStyle(
                            fontSize: 18,
                            fontWeight:
                                FontWeight.w700,
                          ),
                        ),
                        const SizedBox(
                          height: 4,
                        ),
                        Text(
                          'Scegli tra i modelli disponibili del Cantiere.',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            )
                                .colorScheme
                                .onSurface
                                .withValues(
                                  alpha: 0.62,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed:
                        () => Navigator.of(
                      context,
                    ).pop(),
                    icon: const Icon(
                      Icons.close,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(
              height: 1,
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: onRefresh,
                child: ListView.separated(
                  padding:
                      const EdgeInsets.all(
                    14,
                  ),
                  itemCount:
                      candidates.length,
                  separatorBuilder:
                      (_, __) =>
                          const SizedBox(
                    height: 8,
                  ),
                  itemBuilder:
                      (context, index) {
                    final model =
                        candidates[index];

                    final isSelected =
                        model.id ==
                            selectedModelId;

                    final isDownloaded =
                        availability[
                                model.id] ??
                            false;

                    return Card(
                      child: ListTile(
                        onTap: () =>
                            Navigator.of(
                          context,
                        ).pop(model),
                        leading:
                            CircleAvatar(
                          child: Icon(
                            isSelected
                                ? Icons.check
                                : Icons.memory,
                          ),
                        ),
                        title:
                            Text(
                          model.displayName,
                          style:
                              const TextStyle(
                            fontWeight:
                                FontWeight.w600,
                          ),
                        ),
                        subtitle:
                            Padding(
                          padding:
                              const EdgeInsets
                                  .only(
                            top: 4,
                          ),
                          child: Text(
                            '${model.quantization} · '
                            '${_formatBytes(model.sizeBytes)}',
                          ),
                        ),
                        trailing:
                            Column(
                          mainAxisAlignment:
                              MainAxisAlignment
                                  .center,
                          crossAxisAlignment:
                              CrossAxisAlignment
                                  .end,
                          children: [
                            if (isSelected)
                              const Icon(
                                Icons.check_circle,
                                color:
                                    Colors.green,
                              ),
                            const SizedBox(
                              height: 4,
                            ),
                            Text(
                              isDownloaded
                                  ? 'Scaricato'
                                  : 'Da scaricare',
                              style:
                                  const TextStyle(
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _shortRoleName(
    AppAiRole role,
  ) {
    switch (role) {
      case AppAiRole.workshopOrchestrator:
        return 'Orchestratore';
      case AppAiRole.architect:
        return 'Architetto';
      case AppAiRole.engineer:
        return 'Ingegnere';
      case AppAiRole.reviewer:
        return 'Reviewer';
      case AppAiRole.assistantOrchestrator:
        return 'Assistente';
    }
  }

  static String _formatBytes(
    int bytes,
  ) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }

    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }

    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }

    return '$bytes B';
  }
}
