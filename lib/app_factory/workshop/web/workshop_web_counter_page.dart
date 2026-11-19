import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_language.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/link.dart';

enum _CounterAction { recover, prepare, approve, reserve }

/// The fixed counter sample has one server-owned project per Access principal.
class WorkshopWebCounterPage extends StatefulWidget {
  const WorkshopWebCounterPage({super.key});

  @override
  State<WorkshopWebCounterPage> createState() => _WorkshopWebCounterPageState();
}

class _WorkshopWebCounterPageState extends State<WorkshopWebCounterPage> {
  static const _projectId = 'web-counter-v1';
  static const _executionStates = {
    'reserved',
    'running',
    'review_required',
    'failed',
    'completed',
  };

  final _client = http.Client();
  String? _status;
  String? _executionId;
  String? _digest;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _perform(_CounterAction.recover);
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _perform(_CounterAction action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> result;
      switch (action) {
        case _CounterAction.recover:
          result = await _call('/executions/status', read: true);
        case _CounterAction.prepare:
          result = await _call('/proposals/counter');
        case _CounterAction.approve:
          result = await _call('/proposals/approve', extra: {
            'expectedRevision': 1,
            'expectedSpecSha256': _digest,
          });
        case _CounterAction.reserve:
          result = await _call('/executions/reserve');
      }
      if (!mounted) return;
      final status =
          action == _CounterAction.approve ? 'approved' : result['status'];
      final id = result['executionId'];
      final digest = result['specSha256'];
      final valid = switch (action) {
        _CounterAction.recover => result.isEmpty ||
            (_executionStates.contains(status) &&
                id is String &&
                id.isNotEmpty),
        _CounterAction.prepare =>
          (status == 'proposal_ready' || status == 'approved') &&
              digest is String &&
              RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) &&
              result['revision'] == 1 &&
              result['projectId'] == _projectId,
        _CounterAction.approve =>
          result['approvedRevision'] == 1 && result['projectId'] == _projectId,
        _CounterAction.reserve =>
          _executionStates.contains(status) && id is String && id.isNotEmpty,
      };
      if (!valid) throw const FormatException('Unexpected counter response');
      setState(() {
        _status = status as String?;
        _executionId = id as String?;
        if (digest is String) _digest = digest;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Operazione non completata. Controlla la sessione e riprova.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Map<String, dynamic>> _call(
    String path, {
    bool read = false,
    Map<String, Object?> extra = const {},
  }) async {
    final uri = Uri.base.resolve('/api/cantiere$path');
    final response = await (read
            ? _client
                .get(uri.replace(queryParameters: {'projectId': _projectId}))
            : _client.post(uri,
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'projectId': _projectId, ...extra})))
        .timeout(const Duration(seconds: 15));
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
      throw const FormatException('Unexpected counter response');
    }
    if (read &&
        response.statusCode == 404 &&
        decoded['error'] == 'execution_not_found') {
      return {};
    }
    if (response.statusCode != 200 || decoded['ok'] != true) {
      throw const FormatException('Counter request failed');
    }
    return decoded;
  }

  @override
  Widget build(BuildContext context) {
    String tr(String text) => WorkshopWebLanguageScope.tr(context, text);
    final action = switch (_status) {
      null => _CounterAction.prepare,
      'proposal_ready' when _error != null => _CounterAction.prepare,
      'proposal_ready' => _CounterAction.approve,
      'approved' => _CounterAction.reserve,
      _ => _CounterAction.recover,
    };
    final label = switch (action) {
      _CounterAction.prepare => 'Prepara proposta',
      _CounterAction.approve => 'Approva proposta',
      _CounterAction.reserve => 'Prenota esecuzione',
      _CounterAction.recover => 'Aggiorna stato',
    };
    final state = switch (_status) {
      'proposal_ready' => 'Proposta pronta per l’approvazione',
      'approved' => 'Proposta approvata',
      'reserved' => 'Esecuzione prenotata',
      'running' => 'Esecuzione in corso',
      'review_required' => 'Esecuzione da verificare',
      'failed' => 'Esecuzione non riuscita',
      'completed' => 'Esecuzione completata',
      _ => null,
    };
    final executionId = _executionId;
    final downloadUri = _status == 'completed' && executionId != null
        ? Uri.base.resolve('/api/cantiere/executions/download').replace(
            queryParameters: {'executionId': executionId},
          )
        : null;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Contatore Web'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(tr('Contatore con incremento, azzeramento e memoria locale.')),
            if (state != null) Text(tr(state)),
            if (executionId != null) SelectableText(executionId),
            if (_error != null) Text(tr(_error!)),
            const SizedBox(height: 16),
            if (_busy) const LinearProgressIndicator(),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: _busy ? null : () => _perform(action),
                child: Text(tr(label)),
              ),
            ),
            if (downloadUri != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Link(
                  uri: downloadUri,
                  target: LinkTarget.blank,
                  builder: (context, followLink) => OutlinedButton.icon(
                    onPressed: _busy ? null : followLink,
                    icon: const Icon(Icons.download_outlined),
                    label: Text(tr('Scarica ZIP')),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
