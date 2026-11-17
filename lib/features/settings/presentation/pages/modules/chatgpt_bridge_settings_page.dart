import 'dart:io';

import 'package:ai_orchestrator/app/runtime_bootstrap.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// In-app activation for explicit Windows QA builds only.
/// Secrets are never displayed in a public diagnostic page or chat.
class ChatGptBridgeSettingsPage extends StatefulWidget {
  const ChatGptBridgeSettingsPage({super.key});

  @override
  State<ChatGptBridgeSettingsPage> createState() =>
      _ChatGptBridgeSettingsPageState();
}

class _ChatGptBridgeSettingsPageState extends State<ChatGptBridgeSettingsPage> {
  bool _busy = false;
  String? _error;

  String get _mcpScriptPath => p.join(
        p.dirname(Platform.resolvedExecutable),
        'mcp-tools',
        'aivexus_mcp.ps1',
      );

  bool get _hasScript => File(_mcpScriptPath).existsSync();
  bool get _enabled => RuntimeBootstrap.bridgeController?.isEnabled == true;

  Future<void> _operate(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Operazione non riuscita. Verifica che AIVEXUS abbia accesso '
            'all’archivio sicuro e che la porta locale sia libera.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyKey() async {
    await _operate(() async {
      final value =
          await RuntimeBootstrap.bridgeController?.pairingKeyForExplicitCopy();
      if (value == null || value.isEmpty) {
        throw StateError('pairing_key_not_available');
      }
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Chiave copiata. Incollala solo nelle impostazioni MCP di ChatGPT.'),
        ));
      }
    });
  }

  Future<void> _copyScriptPath() async {
    await Clipboard.setData(ClipboardData(text: _mcpScriptPath));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Percorso MCP copiato')),
      );
    }
  }

  Future<void> _disable() async {
    await _operate(() async {
      await RuntimeBootstrap.bridgeController?.disable();
    });
  }

  Future<void> _enable() async {
    await _operate(() async {
      await RuntimeBootstrap.bridgeController?.enable();
    });
  }

  @override
  Widget build(BuildContext context) {
    final allowed = RuntimeBootstrap.localTestBridgeEnabled &&
        Platform.isWindows &&
        RuntimeBootstrap.bridgeController != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Collegamento ChatGPT (test)')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            _enabled ? 'Collegamento locale attivo' : 'Collegamento disattivato',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          const Text(
            'Questo collegamento permette a ChatGPT Desktop di eseguire '
            'soltanto prove sintetiche del motore AIVEXUS. '
            'Non autorizza il controllo del computer né la lettura delle chat.',
          ),
          const SizedBox(height: 16),
          if (!allowed)
            const Text('Funzione disponibile soltanto nella build '
                'Windows di laboratorio con bridge abilitato.'),
          if (allowed) ...[
            FilledButton.icon(
              onPressed: _busy ? null : _enabled ? _disable : _enable,
              icon: Icon(_enabled ? Icons.link_off : Icons.link),
              label: Text(_enabled ? 'Disattiva e revoca' : 'Attiva collegamento'),
            ),
            if (_enabled) ...[
              const SizedBox(height: 20),
              Text(
                'Configura una sola volta ChatGPT Desktop:',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              const SelectableText(
                '1. ChatGPT → Impostazioni → Plugin → MCP → Aggiungi '
                '→ MCP personalizzato → STDIO.\n'
                '2. Nome: AIVEXUS Local Test\n'
                '3. Comando da lanciare: powershell.exe\n'
                '4. Argomenti separati: -NoProfile, -File, '
                'poi il percorso copiato qui sotto.\n'
                '5. Variabile d’ambiente: AIVEXUS_BRIDGE_TOKEN. '
                'Incolla come valore la chiave copiata qui sotto.',
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _hasScript ? _copyScriptPath : null,
                icon: const Icon(Icons.copy),
                label: const Text('Copia percorso del componente MCP'),
              ),
              if (!_hasScript)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Componente MCP non trovato accanto ad AIVEXUS. '
                    'Il pacchetto di laboratorio deve essere completo.',
                    style: TextStyle(color: Colors.orange),
                  ),
                ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _copyKey,
                icon: const Icon(Icons.key),
                label: const Text('Copia chiave di collegamento'),
              ),
              const SizedBox(height: 8),
              const Text(
                'La chiave è riservata: non inviarla in chat, screenshot, '
                'GitHub o Diagnostics. Una volta incollata, evita di '
                'condividerne il contenuto dagli appunti.',
              ),
              const SizedBox(height: 12),
              const Text('Dopo il collegamento, chiedi a ChatGPT: '
                  '“Usa instance_info di AIVEXUS Local Test”.'),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: _busy ? null : () => _operate(() async {
                  await RuntimeBootstrap.bridgeController?.rotateKey();
                }),
                icon: const Icon(Icons.refresh),
                label: const Text('Rigenera chiave e revoca quella precedente'),
              ),
            ],
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.orangeAccent)),
          ],
          const SizedBox(height: 18),
          const Text(
            'Tutto resta sullo stesso ASUS, sulla porta locale 127.0.0.1:47941. '
            'Chiudendo AIVEXUS il servizio si arresta. '
            'Se lo riapri, una precedente attivazione viene ripristinata; '
            'per revocarla usa “Disattiva e revoca”. '
            'Smart App Control rimane invariato.',
          ),
        ],
      ),
    );
  }
}
