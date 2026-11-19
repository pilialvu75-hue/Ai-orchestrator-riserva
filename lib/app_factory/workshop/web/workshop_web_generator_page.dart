import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_language.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class WorkshopWebGeneratorPage extends StatefulWidget {
  const WorkshopWebGeneratorPage({super.key, this.client});

  final http.Client? client;

  @override
  State<WorkshopWebGeneratorPage> createState() =>
      _WorkshopWebGeneratorPageState();
}

class _WorkshopWebGeneratorPageState extends State<WorkshopWebGeneratorPage> {
  static const _storageKey = 'aivexus.web.lastGeneration.v1';
  static final _idPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static final _digestPattern = RegExp(r'^[0-9a-f]{64}$');
  static const _terminalStates = {'generated', 'failed', 'interrupted'};

  final _prompt = TextEditingController();
  late final http.Client _client = widget.client ?? http.Client();
  late final Future<SharedPreferences> _preferences =
      SharedPreferences.getInstance();
  String? _generationId;
  String? _pendingPrompt;
  String? _error;
  Map<String, dynamic>? _receipt;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    if (widget.client == null) _client.close();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    await _run(() async {
      final stored = (await _preferences).getString(_storageKey);
      if (stored == null || !_idPattern.hasMatch(stored) || !mounted) return;
      setState(() => _generationId = stored);
      await _readStatus(stored);
    });
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } on _GeneratorRequestException catch (error) {
      if (mounted) setState(() => _error = error.label);
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = 'Richiesta non completata. Controlla lo stato e riprova.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final prompt = _pendingPrompt ?? _prompt.text.trim();
    if (_busy || prompt.isEmpty) return;
    await _run(() async {
      final id = _generationId ?? const Uuid().v4();
      final saved = await (await _preferences).setString(_storageKey, id);
      if (!saved) {
        throw const _GeneratorRequestException(
            'Impossibile salvare la richiesta nel browser.');
      }
      if (!mounted) return;
      setState(() {
        _generationId = id;
        _pendingPrompt = prompt;
      });
      final result = await _call(id, prompt: prompt);
      if (mounted) setState(() => _receipt = result);
    });
  }

  Future<void> _readStatus(String id) async {
    final result = await _call(id);
    if (!mounted) return;
    if (result == null && _pendingPrompt == null) {
      await (await _preferences).remove(_storageKey);
      if (!mounted) return;
      setState(() => _generationId = null);
    }
    setState(() => _receipt = result);
  }

  Future<void> _reset() async {
    await _run(() async {
      await (await _preferences).remove(_storageKey);
      if (!mounted) return;
      setState(() {
        _generationId = null;
        _pendingPrompt = null;
        _receipt = null;
        _prompt.clear();
      });
    });
  }

  Future<Map<String, dynamic>?> _call(String id, {String? prompt}) async {
    final uri = Uri.base.resolve('/api/cantiere/proposals/generate');
    final response = await (prompt == null
            ? _client.get(uri.replace(queryParameters: {'generationId': id}))
            : _client.post(uri,
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'generationId': id, 'prompt': prompt})))
        .timeout(Duration(seconds: prompt == null ? 15 : 95));
    final result = jsonDecode(utf8.decode(response.bodyBytes));
    if (result is! Map<String, dynamic> || result['version'] != 1) {
      throw const FormatException('Unexpected generation response');
    }
    if (prompt == null &&
        response.statusCode == 404 &&
        result['error'] == 'generation_not_found') {
      return null;
    }
    if (response.statusCode == 429 &&
        result['error'] == 'generation_quota_exceeded') {
      throw const _GeneratorRequestException(
          'Limite di generazione raggiunto. Riprova più tardi.');
    }
    if (response.statusCode == 503 &&
        result['error'] == 'generation_unavailable') {
      throw const _GeneratorRequestException(
          'La generazione Web non è ancora abilitata.');
    }
    if (response.statusCode != 200 ||
        result['ok'] != true ||
        result['generationId'] != id ||
        !{'generating', ..._terminalStates}.contains(result['status'])) {
      throw const FormatException('Invalid generation status');
    }
    if (result['status'] == 'generated') {
      final provenance = result['provenance'];
      final digest = result['sourceSha256'];
      final requirements = result['requirements'];
      final paths = result['paths'];
      if (result['title'] is! String ||
          provenance is! Map ||
          provenance['reportedModel'] is! String ||
          digest is! String ||
          !_digestPattern.hasMatch(digest) ||
          requirements is! List ||
          !requirements.every((item) => item is String) ||
          paths is! List ||
          !paths.every((item) => item is String)) {
        throw const FormatException('Invalid generation receipt');
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    String tr(String label) => WorkshopWebLanguageScope.tr(context, label);
    final id = _generationId;
    final receipt = _receipt;
    final status = receipt?['status'];
    final state = switch (status) {
      'generating' => 'Generazione in corso',
      'generated' => 'Sorgenti generati',
      'failed' => 'Generazione non riuscita',
      'interrupted' => 'Generazione interrotta',
      _ => null,
    };
    return Scaffold(
      appBar: AppBar(title: Text(tr('Genera applicazione'))),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (id == null || _pendingPrompt != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: TextField(
                      controller: _prompt,
                      readOnly: _busy || id != null,
                      minLines: 3,
                      maxLines: 8,
                      maxLength: 1200,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: tr('Descrivi l’applicazione'),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                if (_busy) const LinearProgressIndicator(),
                if (_error case final error?) Text(tr(error)),
                if (state != null)
                  Semantics(liveRegion: true, child: Text(tr(state))),
                if (status == 'generated' && receipt != null) ...[
                  const SizedBox(height: 16),
                  Text(receipt['title'] as String,
                      style: Theme.of(context).textTheme.headlineSmall),
                  for (final item in receipt['requirements'] as List)
                    Text(item as String),
                  const SizedBox(height: 16),
                  Text(tr('File generati')),
                  for (final path in receipt['paths'] as List)
                    SelectableText(path as String),
                  const SizedBox(height: 16),
                  Text(tr('Modello dichiarato')),
                  SelectableText(
                      receipt['provenance']['reportedModel'] as String),
                  const SizedBox(height: 8),
                  const Text('SHA-256'),
                  SelectableText(receipt['sourceSha256'] as String),
                ],
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (id == null ||
                        (status == null && _pendingPrompt != null))
                      FilledButton(
                        onPressed: _busy ||
                                (_pendingPrompt == null &&
                                    _prompt.text.trim().isEmpty)
                            ? null
                            : _submit,
                        child:
                            Text(tr(id == null ? 'Genera' : 'Riprova invio')),
                      ),
                    if (id != null && !_terminalStates.contains(status))
                      OutlinedButton(
                        onPressed:
                            _busy ? null : () => _run(() => _readStatus(id)),
                        child: Text(tr('Aggiorna stato')),
                      ),
                    if (_terminalStates.contains(status) ||
                        (status == null && _pendingPrompt != null))
                      OutlinedButton(
                        onPressed: _busy ? null : _reset,
                        child: Text(tr('Nuova generazione')),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GeneratorRequestException implements Exception {
  const _GeneratorRequestException(this.label);

  final String label;
}
