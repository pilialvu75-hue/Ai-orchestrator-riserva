import 'package:flutter/material.dart';

import 'package:ai_orchestrator/app_factory/workshop/workshop_chat_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_project_storage.dart';

final class WorkshopWebProjectsPage extends StatefulWidget {
  const WorkshopWebProjectsPage({
    super.key,
    required this.controller,
    required this.storage,
  });

  final WorkshopChatController controller;
  final WorkshopWebProjectStorage storage;

  @override
  State<WorkshopWebProjectsPage> createState() =>
      _WorkshopWebProjectsPageState();
}

final class _WorkshopWebProjectsPageState
    extends State<WorkshopWebProjectsPage> {
  static const List<String> _platformOptions = <String>[
    'Android',
    'Web',
    'Windows',
    'macOS',
    'Linux',
    'iOS',
  ];

  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _goalController = TextEditingController();

  List<WorkshopWebProject> _projects = const <WorkshopWebProject>[];
  WorkshopWebProject? _selectedProject;
  final Set<String> _selectedPlatforms = <String>{};
  bool _loading = true;
  bool _showNewProject = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _reload();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _titleController.dispose();
    _goalController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  WorkshopWebProject? _projectById(
    Iterable<WorkshopWebProject> projects,
    String id,
  ) {
    for (final project in projects) {
      if (project.id == id) return project;
    }
    return null;
  }

  Future<void> _reload() async {
    final projects = await widget.storage.loadAll();
    if (!mounted) return;
    setState(() {
      _projects = projects;
      _loading = false;
      final selectedId = _selectedProject?.id;
      if (selectedId != null) {
        _selectedProject = _projectById(projects, selectedId);
      }
    });
  }

  Future<void> _persist(WorkshopWebProject project) async {
    final next = <WorkshopWebProject>[
      project,
      ..._projects.where((item) => item.id != project.id),
    ];
    await widget.storage.save(next);
    if (!mounted) return;
    setState(() {
      _projects = next;
      _selectedProject = project;
    });
  }

  void _startNewProject() {
    widget.controller.clearConversation();
    _titleController.clear();
    _goalController.clear();
    _selectedPlatforms.clear();
    setState(() {
      _selectedProject = null;
      _showNewProject = true;
    });
  }

  Future<void> _prepareProposal() async {
    final title = _titleController.text.trim();
    final goal = _goalController.text.trim();
    final platforms = _selectedPlatforms.toList()..sort();

    if (title.isEmpty || goal.isEmpty || platforms.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Inserisci titolo, almeno una piattaforma e cosa deve fare il progetto.',
          ),
        ),
      );
      return;
    }

    final now = DateTime.now().toUtc();
    var project = WorkshopWebProject(
      id: 'web-project:${now.microsecondsSinceEpoch}',
      title: title,
      goal: goal,
      platforms: List<String>.unmodifiable(platforms),
      status: WorkshopWebProjectStatus.draft,
      progress: 0.05,
      currentPhase: 'Analisi richiesta',
      currentItem: 'Preparazione proposta',
      createdAt: now,
      updatedAt: now,
    );
    await _persist(project);
    if (!mounted) return;

    setState(() {
      _busy = true;
      _showNewProject = false;
    });

    widget.controller.clearConversation();
    final prompt = '''
Titolo progetto: $title
Piattaforme richieste: ${platforms.join(', ')}
Cosa deve fare: $goal

Prepara esclusivamente la proposta del progetto. Non iniziare la creazione,
non dichiarare file creati e non avviare build. Se manca un dato indispensabile
chiedilo con CLARIFY:. Se i dati sono sufficienti rispondi con PROPOSAL: e una
proposta breve, concreta e approvabile.
''';

    final response = await widget.controller.send(prompt);
    if (!mounted) return;

    if (response == null) {
      project = project.copyWith(
        status: WorkshopWebProjectStatus.blocked,
        currentPhase: 'Analisi non completata',
        currentItem: 'Inferenza Cloud / AUTO',
        error: widget.controller.lastError ??
            'Il Cantiere non ha restituito una proposta.',
      );
    } else if (widget.controller.lastResponseReadyForApproval) {
      project = project.copyWith(
        status: WorkshopWebProjectStatus.proposalReady,
        progress: 0.10,
        currentPhase: 'Proposta pronta',
        currentItem: 'Attende approvazione del proprietario',
        proposal: response.content,
        clearError: true,
      );
    } else {
      project = project.copyWith(
        status: WorkshopWebProjectStatus.draft,
        progress: 0.05,
        currentPhase: 'Chiarimento richiesto',
        currentItem: 'Aggiorna “Cosa deve fare?” e riprepara la proposta',
        proposal: response.content,
        clearError: true,
      );
    }

    await _persist(project);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _approveProject() async {
    final project = _selectedProject;
    if (project == null ||
        project.status != WorkshopWebProjectStatus.proposalReady) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Approva progetto'),
        content: Text(
          'Approvi la proposta di “${project.title}”? '
          'Nessuna creazione parte prima di questa conferma.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Approva'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _persist(
      project.copyWith(
        status: WorkshopWebProjectStatus.approved,
        progress: 0.15,
        currentPhase: 'Progetto approvato',
        currentItem: 'Pronto per avvio creazione',
        clearError: true,
      ),
    );
  }

  void _editProject() {
    final project = _selectedProject;
    if (project == null) return;
    _titleController.text = project.title;
    _goalController.text = project.goal;
    _selectedPlatforms
      ..clear()
      ..addAll(project.platforms);
    widget.controller.clearConversation();
    setState(() {
      _selectedProject = null;
      _showNewProject = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_showNewProject) return _buildNewProject();
    if (_selectedProject != null) return _buildProjectDetail(_selectedProject!);
    return _buildProjectList();
  }

  Widget _buildProjectList() {
    final active = _projects
        .where((project) => project.status != WorkshopWebProjectStatus.completed)
        .toList(growable: false);
    final completed = _projects
        .where((project) => project.status == WorkshopWebProjectStatus.completed)
        .toList(growable: false);

    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Aivexus',
                          style: TextStyle(
                            color: Colors.white54,
                            letterSpacing: 1.1,
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Cantiere',
                          style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _startNewProject,
                    icon: const Icon(Icons.add),
                    label: const Text('Nuovo progetto'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                'Ogni progetto ha il proprio stato. La vecchia cronologia chat '
                'globale non viene mescolata con i nuovi progetti.',
                style: TextStyle(color: Colors.white60, height: 1.4),
              ),
              const SizedBox(height: 24),
              _sectionTitle('In corso', active.length),
              if (active.isEmpty)
                const _EmptyProjectCard(text: 'Nessun progetto in corso.')
              else
                ...active.map(_projectCard),
              const SizedBox(height: 18),
              _sectionTitle('Completati', completed.length),
              if (completed.isEmpty)
                const _EmptyProjectCard(text: 'Nessun progetto completato.')
              else
                ...completed.map(_projectCard),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        '$title ($count)',
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }

  Widget _projectCard(WorkshopWebProject project) {
    final percent = (project.progress * 100).round();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: const Icon(Icons.folder_outlined),
        title: Text(
          project.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '${project.platforms.join(' · ')} · ${_statusLabel(project.status)}',
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: project.progress),
              const SizedBox(height: 5),
              Text('$percent% · ${project.currentPhase}'),
            ],
          ),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => setState(() => _selectedProject = project),
      ),
    );
  }

  Widget _buildNewProject() {
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: <Widget>[
              Row(
                children: <Widget>[
                  IconButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _showNewProject = false),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Nuovo progetto',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _titleController,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Titolo',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Piattaforme',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Card(
                child: Column(
                  children: _platformOptions
                      .map(
                        (platform) => CheckboxListTile(
                          value: _selectedPlatforms.contains(platform),
                          title: Text(platform),
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: _busy
                              ? null
                              : (selected) {
                                  setState(() {
                                    if (selected == true) {
                                      _selectedPlatforms.add(platform);
                                    } else {
                                      _selectedPlatforms.remove(platform);
                                    }
                                  });
                                },
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _goalController,
                enabled: !_busy,
                minLines: 5,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: 'Cosa deve fare?',
                  hintText: 'Descrivi il comportamento e il risultato desiderato.',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _busy ? null : _prepareProposal,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_outlined),
                label: Text(
                  _busy ? 'Preparazione in corso…' : 'Prepara proposta',
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'La creazione non parte da questo pulsante. '
                'Prima vedrai la proposta e dovrai approvarla esplicitamente.',
                style: TextStyle(color: Colors.white54, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProjectDetail(WorkshopWebProject project) {
    final percent = (project.progress * 100).round();
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: <Widget>[
              Row(
                children: <Widget>[
                  IconButton(
                    onPressed: () => setState(() => _selectedProject = null),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      project.title,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                project.platforms.join(' · '),
                style: const TextStyle(color: Colors.white60),
              ),
              const SizedBox(height: 22),
              Row(
                children: <Widget>[
                  Expanded(
                    child: LinearProgressIndicator(value: project.progress),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '$percent%',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _infoRow('Fase', project.currentPhase),
              _infoRow('Elemento', project.currentItem),
              _infoRow('Stato', _statusLabel(project.status)),
              const SizedBox(height: 16),
              Text(
                'Cosa deve fare',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(project.goal),
                ),
              ),
              if (project.proposal != null &&
                  project.proposal!.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: 14),
                Text(
                  project.status == WorkshopWebProjectStatus.draft
                      ? 'Domanda / chiarimento del Cantiere'
                      : 'Proposta del Cantiere',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(project.proposal!),
                  ),
                ),
              ],
              if (project.error != null &&
                  project.error!.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.error_outline),
                    title: const Text('Errore'),
                    subtitle: Text(project.error!),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              if (project.status == WorkshopWebProjectStatus.proposalReady)
                FilledButton.icon(
                  onPressed: _approveProject,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Approva progetto'),
                ),
              if (project.status == WorkshopWebProjectStatus.proposalReady ||
                  project.status == WorkshopWebProjectStatus.draft ||
                  project.status == WorkshopWebProjectStatus.blocked) ...<Widget>[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _editProject,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Modifica progetto'),
                ),
              ],
              if (project.status == WorkshopWebProjectStatus.approved) ...<Widget>[
                const SizedBox(height: 8),
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.construction_outlined),
                    title: Text('Inizia creazione'),
                    subtitle: Text(
                      'Il gate è pronto, ma l’esecutore Web server-side non è '
                      'ancora collegato. Il Cantiere non simulerà file o percentuali.',
                    ),
                    trailing: Icon(Icons.lock_clock_outlined),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  static String _statusLabel(WorkshopWebProjectStatus status) {
    return switch (status) {
      WorkshopWebProjectStatus.draft => 'Bozza',
      WorkshopWebProjectStatus.proposalReady => 'Da approvare',
      WorkshopWebProjectStatus.approved => 'Approvato',
      WorkshopWebProjectStatus.inProgress => 'In corso',
      WorkshopWebProjectStatus.blocked => 'Bloccato',
      WorkshopWebProjectStatus.completed => 'Completato',
    };
  }
}

final class _EmptyProjectCard extends StatelessWidget {
  const _EmptyProjectCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white54),
        ),
      ),
    );
  }
}
