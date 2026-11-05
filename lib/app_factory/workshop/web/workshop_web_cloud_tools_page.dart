import 'package:flutter/material.dart';

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_broker.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_self_test.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_language.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_models.dart';

/// Browser-only diagnostics. Does not read local native AI settings.
class WorkshopWebCloudToolsPage extends StatefulWidget {
  const WorkshopWebCloudToolsPage({
    super.key,
    required this.initialTab,
    required this.language,
    required this.preference,
    required this.cloudHealth,
    this.catalogueClient,
    this.selfTestClient,
  });

  final int initialTab;
  final WorkshopWebLanguage language;
  final WorkshopWebModelPreference preference;
  final Future<WorkshopWebCloudBrokerHealth> cloudHealth;
  final WorkshopWebModelCatalogueClient? catalogueClient;
  final WorkshopWebCloudSelfTestClient? selfTestClient;

  @override
  State<WorkshopWebCloudToolsPage> createState() => _WorkshopWebCloudToolsPageState();
}

class _WorkshopWebCloudToolsPageState extends State<WorkshopWebCloudToolsPage> {
  late final WorkshopWebModelCatalogueClient _catalogueClient =
      widget.catalogueClient ?? WorkshopWebModelCatalogueClient();
  late final WorkshopWebCloudSelfTestClient _selfTestClient =
      widget.selfTestClient ?? WorkshopWebCloudSelfTestClient();

  late Future<WorkshopWebModelCatalogue> _catalogue = _loadCatalogue();
  bool _running = false;
  WorkshopWebCloudSelfTestResult? _last;

  String _tr(String source) => widget.language.text(source);

  Future<WorkshopWebModelCatalogue> _loadCatalogue() async {
    final found = await _catalogueClient.load();
    await widget.preference.reconcile(found);
    return found;
  }

  void _refresh() {
    if (!mounted) return;
    setState(() => _catalogue = _loadCatalogue());
  }

  Future<void> _runTest(WorkshopWebModelCatalogue catalogue) async {
    if (_running || !catalogue.hasTestRoutes) return;
    setState(() {
      _running = true;
      _last = null;
    });
    try {
      final result = await _selfTestClient.run(
        selectedRouteId: widget.preference.routeId,
      );
      if (mounted) setState(() => _last = result);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Widget _modelsPanel(WorkshopWebModelCatalogue catalogue) {
    return AnimatedBuilder(
      animation: widget.preference,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            _tr('Seleziona un modello per il Cantiere'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(_tr(
            'AUTO segue le rotte configurate sul server. La selezione manuale '
            'è limitata alle rotte autorizzate a costo zero.',
          )),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              key: const Key('web_model_auto'),
              leading: Icon(
                widget.preference.automatic
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(_tr('AUTO (predefinito)')),
              subtitle: Text(_tr('Ordine e failover gestiti dal server')),
              onTap: () => widget.preference.select(null),
            ),
          ),
          for (final route in catalogue.models)
            Card(
              child: ListTile(
                key: Key('web_model_${route.routeId}'),
                enabled: route.selectable,
                leading: Icon(widget.preference.routeId == route.routeId
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                title: Text('${route.provider} · ${route.model}'),
                subtitle: Text(
                  '${_tr('Rotta')}: ${route.routeId}${route.manualOnly ? ' · MANUALE' : ''}\n'
                  '${_tr('Binding presente')}: ${route.bindingPresent ? _tr('Sì') : _tr('No')} · '
                  '${_tr('Test gratuito autorizzato')}: ${route.testApproved ? _tr('Sì') : _tr('No')}',
                ),
                isThreeLine: true,
                onTap: route.selectable
                    ? () => widget.preference.select(route)
                    : null,
              ),
            ),
          if (catalogue.models.isEmpty)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(_tr('Nessuna rotta configurata visibile')),
              subtitle: Text('${_tr('Stato configurazione')}: ${catalogue.configStatus}'),
            ),
          if (!catalogue.hasTestRoutes)
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: Text(_tr('Nessun modello autorizzato per il Self-Test')),
              subtitle: Text(_tr('Il server deve autorizzare esplicitamente '
                  'una rotta gratuita. Non è un errore del modello.')),
            ),
        ],
      ),
    );
  }

  Widget _testPanel(WorkshopWebModelCatalogue catalogue) {
    final result = _last;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(_tr('Test reale del broker Cloud'),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        Text(_tr('Il test invia un messaggio sintetico. Non usa i progetti salvati.')),
        const SizedBox(height: 8),
        Text('${_tr('Modello selezionato')}: ${widget.preference.routeId ?? 'AUTO'}'),
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const Key('web_run_cloud_self_test'),
          onPressed: _running || !catalogue.hasTestRoutes
              ? null : () => _runTest(catalogue),
          icon: _running
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.science_outlined),
          label: Text(_running ? _tr('Test in corso…') : _tr('Esegui Self-Test Cloud')),
        ),
        if (!catalogue.hasTestRoutes)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_tr('Test non configurato: nessuna rotta autorizzata a costo zero.')),
          ),
        if (result != null) ...<Widget>[
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(children: <Widget>[
                    Icon(result.passed ? Icons.check_circle : Icons.info_outline),
                    const SizedBox(width: 8),
                    Text(result.passed ? 'PASS' : 'NOT PASSED',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ]),
                  const SizedBox(height: 10),
                  Text(result.detail),
                  Text('HTTP ${result.statusCode ?? '—'} · ${result.elapsed.inMilliseconds} ms'),
                  if (result.provider != null) Text('${_tr('Provider')}: ${result.provider}'),
                  if (result.configuredModel != null)
                    Text('${_tr('Modello configurato')}: ${result.configuredModel}'),
                  if (result.reportedModel != null)
                    Text('${_tr('Modello dichiarato')}: ${result.reportedModel}'),
                  if (result.routeId != null) Text('${_tr('Rotta')}: ${result.routeId}'),
                  if (result.tokensGenerated != null)
                    Text('${_tr('Token generati')}: ${result.tokensGenerated}'),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _diagnosticsPanel(WorkshopWebModelCatalogue catalogue) {
    final withBinding = catalogue.models.where((m) => m.bindingPresent).length;
    final withTest = catalogue.models.where((m) => m.selectable).length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(_tr('Diagnostica configurazione'),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(title: Text(_tr('Stato configurazione')),
            subtitle: Text(catalogue.configStatus)),
        ListTile(title: Text(_tr('Rotte configurate')),
            trailing: Text('${catalogue.models.length}')),
        ListTile(title: Text(_tr('Binding presenti')),
            trailing: Text('$withBinding')),
        ListTile(title: Text(_tr('Rotte autorizzate per il test')),
            trailing: Text('$withTest')),
        if (catalogue.httpStatus != null)
          ListTile(title: const Text('HTTP catalogo'),
              trailing: Text('${catalogue.httpStatus}')),
        if (catalogue.errorCode != null)
          ListTile(title: Text(_tr('Errore catalogo')),
              subtitle: Text(catalogue.errorCode!)),
        FutureBuilder<WorkshopWebCloudBrokerHealth>(
          future: widget.cloudHealth,
          builder: (context, snapshot) => ListTile(
            title: const Text('Cloud / AUTO'),
            subtitle: Text(snapshot.hasError
                ? 'error'
                : snapshot.data == null ? 'checking'
                : snapshot.data!.isReady ? 'Available' : 'Not configured'),
          ),
        ),
        Text(_tr('Un binding presente non dimostra che la credenziale '
            'sia accettata dal provider o che il modello risponda.')),
        const SizedBox(height: 8),
        Text(_tr('Per la conferma serve un Self-Test con modello '
            'dichiarato e testo finale valido.')),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _refresh,
          icon: const Icon(Icons.refresh),
          label: Text(_tr('Aggiorna diagnosi')),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab < 0 ? 0 : widget.initialTab > 2 ? 2 : widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_tr('Strumenti Cloud')),
          bottom: TabBar(tabs: <Widget>[
            Tab(text: _tr('Self-Test')),
            Tab(text: _tr('Scelta modello')),
            Tab(text: _tr('Diagnostica')),
          ]),
        ),
        body: FutureBuilder<WorkshopWebModelCatalogue>(
          future: _catalogue,
          builder: (context, snapshot) {
            if (snapshot.data == null) {
              if (snapshot.hasError) {
                return Center(child: Text(_tr('Catalogo non raggiungibile')));
              }
              return const Center(child: CircularProgressIndicator());
            }
            final catalog = snapshot.data!;
            return TabBarView(children: <Widget>[
              _testPanel(catalog),
              _modelsPanel(catalog),
              _diagnosticsPanel(catalog),
            ]);
          },
        ),
      ),
    );
  }
}
