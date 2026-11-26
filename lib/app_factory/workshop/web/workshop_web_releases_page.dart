import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/link.dart';
import 'package:uuid/uuid.dart';

class WorkshopWebReleasesPage extends StatefulWidget {
  const WorkshopWebReleasesPage(
      {super.key, required this.generationId, required this.client});

  final String generationId;
  final http.Client client;

  @override
  State<WorkshopWebReleasesPage> createState() =>
      _WorkshopWebReleasesPageState();
}

class _WorkshopWebReleasesPageState extends State<WorkshopWebReleasesPage> {
  final _newId = const Uuid().v4();
  final _api = Uri.base.resolve('/api/cantiere/proposals/release');
  Map<String, dynamic>? _active;
  List<Map<String, dynamic>> _history = [];
  String? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _run(_load);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on _ReleaseFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Pubblicazione non disponibile.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    final response = await widget.client
        .get(_api
            .replace(queryParameters: {'generationId': widget.generationId}))
        .timeout(const Duration(seconds: 15));
    final result = _decode(response);
    final history = result['history'];
    if (history is! List) {
      throw const FormatException('Invalid release history');
    }
    final releases =
        history.whereType<Map<String, dynamic>>().toList(growable: false);
    if (releases.length != history.length ||
        releases.any((row) =>
            row['revision'] is! int ||
            row['releaseId'] is! String ||
            row['generationId'] is! String)) {
      throw const FormatException('Invalid release entry');
    }
    if (mounted) {
      setState(() {
        _history = releases;
        _active = releases.isEmpty ? null : releases.first;
      });
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    final result = jsonDecode(utf8.decode(response.bodyBytes));
    if (result is! Map<String, dynamic> || result['version'] != 1) {
      throw const FormatException('Invalid release response');
    }
    if (response.statusCode == 409) {
      throw const _ReleaseFailure(
          'La pubblicazione è cambiata. Aggiorna e riprova.');
    }
    if (response.statusCode == 503 &&
        result['error'] == 'release_unavailable') {
      throw const _ReleaseFailure('La pubblicazione privata non è abilitata.');
    }
    if (response.statusCode != 200 || result['ok'] != true) {
      throw const FormatException('Release request failed');
    }
    return result;
  }

  Future<void> _change(String action, String generationId) async {
    await _run(() async {
      final response = await widget.client
          .post(
            _api,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'action': action,
              'generationId': generationId,
              'releaseId': _active?['releaseId'] ?? _newId,
              'expectedRevision': _active?['revision'] ?? 0
            }),
          )
          .timeout(const Duration(seconds: 15));
      _decode(response);
      await _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    final target = active == null
        ? null
        : Uri.base.resolve('/api/cantiere/proposals/launch').replace(
            queryParameters: {'releaseId': active['releaseId'] as String});
    return Scaffold(
      appBar: AppBar(title: const Text('Pubblicazione privata')),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error case final error?) Text(error),
        if (target != null) ...[
          SelectableText(target.toString()),
          Align(
              alignment: Alignment.centerLeft,
              child: Link(
                uri: target,
                target: LinkTarget.blank,
                builder: (_, follow) => TextButton(
                    onPressed: follow,
                    child: const Text('Apri app pubblicata')),
              )),
        ],
        Wrap(spacing: 12, children: [
          FilledButton(
            onPressed: _busy || active?['generationId'] == widget.generationId
                ? null
                : () => _change('publish', widget.generationId),
            child: Text(active == null
                ? 'Crea link privato'
                : 'Aggiorna il link a questa versione'),
          ),
          TextButton(
              onPressed: _busy ? null : () => _run(_load),
              child: const Text('Aggiorna')),
        ]),
        for (final event in _history)
          ListTile(
            title: Text('Pubblicazione ${event['revision']}'),
            subtitle: Text(event['action'] == 'rollback'
                ? 'Versione ripristinata'
                : 'Versione pubblicata'),
            trailing: event['generationId'] == active?['generationId']
                ? const Icon(Icons.check_circle_outline)
                : TextButton(
                    onPressed: _busy
                        ? null
                        : () => _change(
                            'rollback', event['generationId'] as String),
                    child: const Text('Ripristina'),
                  ),
          ),
      ]),
    );
  }
}

class _ReleaseFailure implements Exception {
  const _ReleaseFailure(this.message);
  final String message;
}
