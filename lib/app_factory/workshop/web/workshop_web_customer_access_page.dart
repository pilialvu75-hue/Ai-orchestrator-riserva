import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'workshop_web_language.dart';

/// Private invitation UI. The server, not the UI, decides all permissions.
class WorkshopWebCustomerAccessPage extends StatefulWidget {
  const WorkshopWebCustomerAccessPage({super.key, this.client, this.invitationId});
  final http.Client? client;
  final String? invitationId;

  @override
  State<WorkshopWebCustomerAccessPage> createState() =>
      _WorkshopWebCustomerAccessPageState();
}

class _WorkshopWebCustomerAccessPageState
    extends State<WorkshopWebCustomerAccessPage> {
  late final http.Client _client;
  final TextEditingController _email = TextEditingController();
  String _role = 'uninvited';
  String? _error, _notice, _invite;
  List<Map<String, dynamic>> _invitations = const [];
  bool _busy = false, _ready = false, _enabled = false;
  int _days = 7;

  String t(String value) => WorkshopWebLanguageScope.of(context).text(value);

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? http.Client();
    _invite = widget.invitationId;
    _email.addListener(_emailChanged);
    unawaited(_refresh());
  }

  void _emailChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _email.removeListener(_emailChanged);
    _email.dispose();
    if (widget.client == null) _client.close();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(String path,
      {Map<String, dynamic>? payload}) async {
    final uri = Uri.base.resolve('/api/cantiere/access/' + path);
    final response = await (payload == null
        ? _client.get(uri)
        : _client.post(uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload))).timeout(const Duration(seconds: 12));
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic> || decoded['ok'] != true) {
      throw StateError(response.statusCode == 403
          ? t('Accesso non autorizzato.')
          : response.statusCode == 503
              ? t('Servizio accessi non disponibile.')
              : t('Operazione non riuscita.'));
    }
    return decoded;
  }

  Future<void> _refresh() async {
    if (!mounted || _busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final status = await _call('status');
      final role = status['role']?.toString() ?? 'uninvited';
      List<Map<String, dynamic>> items = const [];
      if (role == 'owner') {
        final page = await _call('invitations');
        items = (page['invitations'] as List? ?? const [])
            .whereType<Map<String, dynamic>>().toList();
      }
      if (mounted) {
        setState(() {
          _ready = true;
          _role = role;
          _enabled = status['clientEnabled'] == true;
          _invitations = items;
        });
      }
    } catch (error) {
      if (mounted) setState(() {
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(String operation, Map<String, dynamic> payload) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; _notice = null; });
    try {
      await _call(operation, payload: payload);
      if (mounted) setState(() {
        _notice = operation == 'invitations' ? t('Invito privato creato.')
            : operation == 'revoke' ? t('Accesso revocato.')
            : t('Invito accettato.');
        if (operation == 'invitations') _email.clear();
        if (operation == 'claim') _invite = null;
      });
    } catch (error) {
      if (mounted) setState(() {
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final owner = _role == 'owner';
    return Scaffold(
      appBar: AppBar(
        title: Text(t('Accessi clienti')),
        actions: [
          IconButton(key: const Key('web_customer_refresh'),
            tooltip: t('Aggiorna'), icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _refresh),
        ],
      ),
      body: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: ListView(padding: const EdgeInsets.all(20), children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (_notice != null)
            Text(_notice!, key: const Key('web_customer_notice')),
          if (!_ready) Text(t('Verifica accesso in corso.')),
          if (_ready && owner) ...[
            Text(t('Proprietario AIVEXUS'),
              style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            Text(t('Gli inviti non aprono Cloudflare Access. '
                'Autorizza separatamente il destinatario nella policy privata.')),
            const SizedBox(height: 16),
            TextField(
              key: const Key('web_customer_email'), controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(labelText: t('Email del cliente'),
                border: const OutlineInputBorder())),
            const SizedBox(height: 12),
            Row(children: [
              Text(t('Validità')),
              const SizedBox(width: 12),
              DropdownButton<int>(
                key: const Key('web_customer_duration'), value: _days,
                items: [1, 3, 7, 14, 30].map((n) => DropdownMenuItem<int>(
                  value: n, child: Text(n.toString() + ' ' + t('giorni'))))
                  .toList(),
                onChanged: _busy ? null : (n) {
                  if (n != null) setState(() => _days = n);
                }),
              const Spacer(),
              FilledButton.icon(
                key: const Key('web_customer_create'),
                onPressed: _busy || _email.text.trim().isEmpty ? null
                  : () => _submit('invitations', {
                      'email': _email.text.trim(), 'expiresDays': _days,
                    }),
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: Text(t('Crea invito'))),
            ]),
            const SizedBox(height: 24),
            Text(t('Inviti privati'),
              style: Theme.of(context).textTheme.titleMedium),
            if (_invitations.isEmpty) Text(t('Nessun invito disponibile.')),
            for (final item in _invitations)
              Card(child: ListTile(
                title: Text(item['recipientEmail']?.toString() ?? ''),
                subtitle: Text((item['status']?.toString() ?? '') +
                  ' · ' + (item['expiresAt']?.toString() ?? '')),
                trailing: Wrap(mainAxisSize: MainAxisSize.min, children: [
                  if (item['status'] == 'pending') IconButton(
                    key: Key('web_customer_copy_' +
                      (item['invitationId']?.toString() ?? '')),
                    tooltip: t('Copia link invito'),
                    onPressed: () async {
                      final id = item['invitationId']?.toString();
                      if (id != null) {
                        await Clipboard.setData(ClipboardData(
                          text: Uri.base.resolve('/?invite=' + id).toString()));
                      }
                    }, icon: const Icon(Icons.copy_outlined)),
                  if (item['status'] == 'pending' ||
                      item['status'] == 'accepted') IconButton(
                    tooltip: t('Revoca accesso'),
                    onPressed: _busy ? null : () => _submit('revoke', {
                      'invitationId': item['invitationId'],
                    }), icon: const Icon(Icons.block_outlined)),
                ]),
              )),
          ] else if (_ready && _role == 'client') ...[
            Text(t('Invito accettato'),
              style: Theme.of(context).textTheme.titleLarge),
            Text(_enabled
              ? t('Accesso cliente attivo. Sono disponibili solo i tuoi progetti.')
              : t('Il tuo invito è valido. L’apertura ai clienti non è ancora attiva.')),
          ] else if (_ready) ...[
            Text(t('Accesso clienti'),
              style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(t('Per accedere serve un invito privato e '
                'un login Cloudflare Access con la stessa email.')),
            if (_invite != null) Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: FilledButton.icon(
                key: const Key('web_customer_claim'),
                onPressed: _busy ? null :
                  () => _submit('claim', {'invitationId': _invite}),
                icon: const Icon(Icons.verified_user_outlined),
                label: Text(t('Accetta invito')))),
          ],
        ])),
      ),
    );
  }
}
