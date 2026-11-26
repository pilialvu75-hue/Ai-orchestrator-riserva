import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_preview_frame.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class WorkshopWebJoinedAppPage extends StatefulWidget {
  const WorkshopWebJoinedAppPage({super.key, this.client});

  final http.Client? client;

  @override
  State<WorkshopWebJoinedAppPage> createState() =>
      _WorkshopWebJoinedAppPageState();
}

class _WorkshopWebJoinedAppPageState extends State<WorkshopWebJoinedAppPage> {
  static const _storageKey = 'aivexus.web.joinedApp.v1';
  static final _generationPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9+/]{43}=$');
  late final http.Client _client = widget.client ?? http.Client();
  late final _preferences = SharedPreferences.getInstance();
  final _input = TextEditingController();
  String? _id;
  String? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _input.dispose();
    if (widget.client == null) _client.close();
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      final id = (await _preferences).getString(_storageKey);
      if (id != null && _generationPattern.hasMatch(id) && mounted) {
        setState(() => _id = id);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Impossibile recuperare l’app precedente.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() async {
    final token = _input.text.trim();
    if (_busy || !_tokenPattern.hasMatch(token)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final response = await _client
          .post(
            Uri.base.resolve('/api/cantiere/proposals/join'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'token': token}),
          )
          .timeout(const Duration(seconds: 15));
      final result = jsonDecode(utf8.decode(response.bodyBytes));
      final id = result is Map<String, dynamic> ? result['generationId'] : null;
      if (response.statusCode != 200 ||
          result is! Map<String, dynamic> ||
          result['ok'] != true ||
          result['version'] != 1 ||
          id is! String ||
          !_generationPattern.hasMatch(id)) {
        throw const FormatException('Invalid application invitation');
      }
      if (!mounted) return;
      await (await _preferences).setString(_storageKey, id);
      if (mounted) {
        setState(() {
          _input.clear();
          _id = id;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Invito non valido o non disponibile.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = _id;
    return Scaffold(
      appBar: AppBar(title: const Text('App con invito'), actions: [
        if (id != null)
          TextButton(
              onPressed: () => setState(() {
                    _id = null;
                    _error = null;
                  }),
              child: const Text('Altro invito')),
      ]),
      body: id != null
          ? WorkshopWebPreviewFrame(
              uri: Uri.base
                  .resolve('/api/cantiere/proposals/view')
                  .replace(queryParameters: {'generationId': id}))
          : ListView(padding: const EdgeInsets.all(24), children: [
              TextField(
                  controller: _input,
                  obscureText: true,
                  autocorrect: false,
                  enabled: !_busy,
                  onChanged: (_) => setState(() {}),
                  decoration:
                      const InputDecoration(labelText: 'Codice di invito')),
              if (_busy) const LinearProgressIndicator(),
              if (_error case final error?) Text(error),
              const SizedBox(height: 16),
              Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed:
                        _busy || !_tokenPattern.hasMatch(_input.text.trim())
                            ? null
                            : _join,
                    child: const Text('Accetta e apri app'),
                  )),
            ]),
    );
  }
}
