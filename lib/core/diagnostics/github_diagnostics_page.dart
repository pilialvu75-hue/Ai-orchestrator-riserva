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
  final _service = GitHubDiagnostics.instance;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _service.initialize();
  }

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _configure(bool enabled) async {
    setState(() => _saving = true);
    try {
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
    appBar: AppBar(title: const Text('Log su GitHub')),
    body: ListenableBuilder(
      listenable: _service,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(GitHubDiagnostics.repository),
          const SizedBox(height: 12),
          const Text('Invia automaticamente eventi tecnici filtrati da Runtime Diagnostics e dal log crash su disco. '
            'I dati pubblicati sono pubblici. Testi delle chat, percorsi, token e messaggi liberi delle eccezioni restano sul telefono.'),
          const SizedBox(height: 12),
          const Text('File fino a 1 MiB, archivio fino a 20 MiB. latest.txt contiene fino a 250 KiB. '
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
            onPressed: () => Clipboard.setData(const ClipboardData(
              text: 'https://github.com/${GitHubDiagnostics.repository}/releases/tag/${GitHubDiagnostics.tag}',
            )),
            child: const Text('Copia link ai log'),
          ),
        ],
      ),
    ),
  );
}
