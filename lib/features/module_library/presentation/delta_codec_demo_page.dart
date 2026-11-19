import 'package:ai_orchestrator/features/module_library/domain/delta_codec.dart';
import 'package:flutter/material.dart';

/// On-device demonstration of the original Qwen-generated Library module.
/// No network, inference runtime or GitHub credentials required.
class DeltaCodecDemoPage extends StatefulWidget {
  const DeltaCodecDemoPage({super.key});

  @override
  State<DeltaCodecDemoPage> createState() => _DeltaCodecDemoPageState();
}

class _DeltaCodecDemoPageState extends State<DeltaCodecDemoPage> {
  final _controller = TextEditingController(text: '12, -4, -4, 9, 0');
  String? _encoded;
  String? _decoded;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _run() {
    try {
      final raw = _controller.text.trim();
      final samples = raw.isEmpty
          ? <int>[]
          : raw.split(',').map((value) => int.parse(value.trim())).toList();
      final encoded = encodeDeltas(samples);
      final decoded = decodeDeltas(encoded);
      if (decoded.length != samples.length ||
          !List.generate(samples.length, (i) => decoded[i] == samples[i])
              .every((same) => same)) {
        throw StateError('Il risultato non coincide con i dati originali');
      }
      setState(() {
        _encoded = encoded.join(', ');
        _decoded = decoded.join(', ');
        _error = null;
      });
    } catch (_) {
      setState(() {
        _encoded = null;
        _decoded = null;
        _error = 'Inserisci numeri interi separati da virgole, ad esempio 12, -4, 9.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Delta Codec — modulo locale')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('Modulo Qwen originale della Libreria. Esegue codifica e decodifica sul dispositivo, anche offline.'),
            const SizedBox(height: 8),
            const Text('Stato: qualificato per sviluppo, non certificato per distribuzione.'),
            const SizedBox(height: 20),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.text,
              decoration: const InputDecoration(
                labelText: 'Numeri interi separati da virgole',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Esegui modulo'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (_encoded != null) ...[
              const SizedBox(height: 20),
              SelectableText('Codifica delta: $_encoded'),
              const SizedBox(height: 8),
              SelectableText('Decodifica: $_decoded'),
              const SizedBox(height: 8),
              const Text('PASS: i valori decodificati coincidono con gli originali.'),
            ],
          ],
        ),
      );
}
