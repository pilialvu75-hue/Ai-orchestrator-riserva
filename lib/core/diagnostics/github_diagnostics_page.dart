import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ai_orchestrator/core/diagnostics/github_diagnostics.dart';

class GitHubDiagnosticsPage extends StatefulWidget {
  const GitHubDiagnosticsPage({super.key});
  @override
  State<GitHubDiagnosticsPage> createState() => _GitHubDiagnosticsPageState();
}

class _GitHubDiagnosticsPageState extends State<GitHubDiagnosticsPage> {
  final _token = TextEditingController();
  final _name = TextEditingController();
  final _service = GitHubDiagnostics.instance;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _service.initialize().then((_) {
      if (mounted) setState(() => _name.text = _service.deviceName);
    });
  }

  @override
  void dispose() {
    _token.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _configure(bool enabled) async {
    setState(() => _saving = true);
    try {
      await _service.renameDevice(_name.text);
      await _service.configure(_token.text, enabled);
      _token.clear();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Configurazione non riuscita. Inserisci un token valido e riprova.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Diagnostica e dispositivi')),
    body: ListenableBuilder(
      listenable: _service,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(GitHubDiagnostics.repository),
          TextField(controller: _name, maxLength: 40, decoration: const InputDecoration(
            labelText: 'Nome pubblico del dispositivo',
            helperText: 'Lettere, numeri, spazi e trattini. Evita dati personali.',
          )),
          SelectableText('Installazione: ${_service.installationId}'),
          Text('In attesa: ${_service.queuedFiles} file — ${(_service.queuedBytes / (1024 * 1024)).toStringAsFixed(2)} / 20 MiB'),
          Text('Ultimo invio riuscito: ${_service.lastUpload?.toLocal() ?? "mai"}'),
          const SizedBox(height: 12),
          const Text('Invia automaticamente eventi tecnici filtrati da Runtime Diagnostics e dal log crash su disco. '
            'I dati pubblicati sono pubblici. Testi delle chat, percorsi, token e messaggi liberi delle eccezioni restano sul telefono.'),
          const SizedBox(height: 12),
          const Text('File fino a 1 MiB, archivio fino a 20 MiB per dispositivo. latest.txt contiene fino a 250 KiB. '
            'Invio ogni minuto mentre l’app è attiva; dopo un crash riprende al riavvio. '
            'Quando la coda è piena, i file più vecchi vengono eliminati.'),
          const SizedBox(height: 16),
          TextField(
            controller: _token, obscureText: true, autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Token GitHub dedicato',
              helperText: 'Fine-grained: solo questo repository, Contents lettura/scrittura.\nLascia vuoto per mantenere il token già salvato.',
              helperMaxLines: 3,
            ),
          ),
          SwitchListTile(
            title: const Text('Invio automatico'), value: _service.enabled,
            onChanged: _saving || _service.busy ? null : _configure,
          ),
          FilledButton(
            onPressed: _saving || _service.busy ? null : () => _configure(_service.enabled),
            child: const Text('Salva configurazione'),
          ),
          OutlinedButton(
            onPressed: !_service.enabled || _service.busy ? null : _service.sync,
            child: const Text('Invia ora'),
          ),
          Text(_service.status),
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(
              text: _service.releaseUrl,
            )),
            child: const Text('Copia link ai log'),
          ),
        ],
      ),
    ),
  );
}
