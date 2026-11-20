import 'dart:convert';

import 'package:ai_orchestrator/app_factory/workshop/workshop_chat_controller.dart';
import 'package:ai_orchestrator/app_factory/workshop/workshop_inference_gateway.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_cloud_broker.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_models.dart';
import 'package:ai_orchestrator/core/runtime/inference/chat_turn.dart';

import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_language.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_preview_frame.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_generator_workspace.dart';
import 'package:ai_orchestrator/app_factory/workshop/web/workshop_web_source_page.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/link.dart';
import 'package:uuid/uuid.dart';

class WorkshopWebGeneratorPage extends StatefulWidget {
  const WorkshopWebGeneratorPage({
    super.key,
    this.client,
    this.modelPreference,
  });

  final http.Client? client;
  /// Uses the already-configured Web Cloud/AUTO route; no new backend.
  final WorkshopWebModelPreference? modelPreference;

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
  static const _verificationStates = {
    'ready',
    'checks_missing',
    'dispatching',
    'submitted',
    'importing',
    'review_required',
    'verified',
    'failed',
    'unavailable',
  };

  final _prompt = TextEditingController();
  final _chatInput = TextEditingController();
  final List<ChatTurn> _chatTurns = <ChatTurn>[];
  WorkshopChatController? _chatController;
  bool _firstChatTurn = true;
  late final http.Client _client = widget.client ?? http.Client();
  late final Future<SharedPreferences> _preferences =
      SharedPreferences.getInstance();
  String? _generationId;
  String? _pendingPrompt;
  String? _error;
  Map<String, dynamic>? _receipt;
  Map<String, dynamic>? _verification;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    final preference = widget.modelPreference;
    if (preference != null) {
      _chatController = WorkshopChatController(
        inferenceGateway: WorkshopInferenceGateway(
          provider: WorkshopWebCloudRuntimeProvider(
            capability: WorkshopWebCloudCapability.orchestration,
            selectedRouteId: () => preference.routeId,
          ),
        ),
        sessionId: 'web-generator-${const Uuid().v4()}',
      );
    }
    _chatController?.addListener(_onChatControllerChanged);
    _restore();
  }

  @override
  void dispose() {
    if (widget.client == null) _client.close();
    _prompt.dispose();
    _chatInput.dispose();
    _chatController?.removeListener(_onChatControllerChanged);
    _chatController?.dispose();
    super.dispose();
  }

  void _onChatControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _restore() async {
    await _run(() async {
      final requested = Uri.base.queryParameters['generationId'];
      if (requested != null && _idPattern.hasMatch(requested)) {
        final receipt = await _call(requested);
        if (receipt != null && mounted) {
          setState(() {
            _generationId = requested;
            _receipt = receipt;
          });
          if (receipt['status'] == 'generated') await _readVerification(requested);
          return;
        }
      }
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
      if (!mounted) return;
      setState(() => _receipt = result);
      if (result?['status'] == 'generated') await _readVerification(id);
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
    if (result?['status'] == 'generated') await _readVerification(id);
  }

  Future<void> _readVerification(String id, {bool advance = false}) async {
    final uri = Uri.base.resolve('/api/cantiere/proposals/verify');
    final response = await (advance
            ? _client.post(uri,
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'generationId': id}))
            : _client.get(uri.replace(queryParameters: {'generationId': id})))
        .timeout(const Duration(seconds: 50));
    final result = jsonDecode(utf8.decode(response.bodyBytes));
    if (result is! Map<String, dynamic> || result['version'] != 1) {
      throw const FormatException('Invalid application verification response');
    }
    if (response.statusCode == 503 &&
        result['error'] == 'verification_unavailable') {
      throw const _GeneratorRequestException(
          'Verifica temporaneamente non disponibile.');
    }
    if (response.statusCode != 200 ||
        result['ok'] != true ||
        result['generationId'] != id ||
        !_verificationStates.contains(result['status'])) {
      throw const FormatException('Invalid application verification status');
    }
    if (result['status'] == 'verified') {
      final digest = result['zipSha256'];
      final sourceDigest = result['sourceSha256'];
      if (digest is! String ||
          !_digestPattern.hasMatch(digest) ||
          sourceDigest is! String ||
          !_digestPattern.hasMatch(sourceDigest)) {
        throw const FormatException('Invalid verification digest');
      }
    }
    if (mounted) setState(() => _verification = result);
  }

  Future<void> _reset() async {
    await _run(() async {
      await (await _preferences).remove(_storageKey);
      if (!mounted) return;
      setState(() {
        _generationId = null;
        _pendingPrompt = null;
        _receipt = null;
        _verification = null;
        _prompt.clear();
        _chatInput.clear();
        _chatTurns.clear();
        _firstChatTurn = true;
      });
    });
  }

  Uri _generationResource(String route, String id) => Uri.base
      .resolve('/api/cantiere/proposals/$route')
      .replace(queryParameters: {'generationId': id});

  Future<Map<String, String>> _loadSource(String id) async {
    final response = await _client
        .get(_generationResource('source', id))
        .timeout(const Duration(seconds: 15));
    final result = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200 ||
        result is! Map<String, dynamic> ||
        result['version'] != 1 ||
        result['ok'] != true ||
        result['generationId'] != id ||
        result['sourceSha256'] != _verification?['sourceSha256']) {
      throw const FormatException('Invalid verified source response');
    }
    final source = result['source'];
    if (source is! Map<String, dynamic> || source['files'] is! List) {
      throw const FormatException('Invalid source files');
    }
    final files = <String, String>{};
    for (final entry in source['files'] as List) {
      if (entry is! Map<String, dynamic> ||
          entry['path'] is! String ||
          entry['content'] is! String) {
        throw const FormatException('Invalid source file');
      }
      final path = entry['path'] as String;
      if (files.containsKey(path))
        throw const FormatException('Duplicate source file');
      files[path] = entry['content'] as String;
    }
    if (!files.containsKey('index.html'))
      throw const FormatException('Missing entry point');
    return files;
  }

  void _openSources(String id) {
    final files = _loadSource(id);
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => WorkshopWebSourcePage(files: files),
    ));
  }

  void _openPreview(String id) {
    final title = WorkshopWebLanguageScope.tr(context, 'Anteprima');
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: WorkshopWebPreviewFrame(uri: _generationResource('preview', id)),
      ),
    ));
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

  Future<void> _sendChatMessage() async {
    final controller = _chatController;
    final message = _chatInput.text.trim();
    if (controller == null || controller.isBusy || message.isEmpty) return;

    controller.setPreferredWebResponseLanguage(
      WorkshopWebLanguageScope.maybeOf(context)?.replyLanguageName ??
          'italiano',
    );

    _chatInput.clear();
    setState(() {
      _chatTurns.add(ChatTurn(role: ChatRole.user, content: message));
    });

    // Preserve the first generator prompt as context for the existing
    // conversational Web agent. This does not call the generation API again.
    final original = (_pendingPrompt ?? _prompt.text).trim();
    final contextualMessage = _firstChatTurn && original.isNotEmpty
        ? 'Richiesta iniziale dell’applicazione:\n$original\n\n'
            'Domanda o modifica da discutere:\n$message'
        : message;
    _firstChatTurn = false;

    final response = await controller.send(contextualMessage);
    if (!mounted) return;
    setState(() {
      if (response != null) _chatTurns.add(response);
    });
  }

  Widget _firstPromptEditor(String Function(String) tr) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 10),
              const Text(
                'AIVEXUS Studio',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.6,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tr('Descrivi la tua applicazione. Puoi modificare il testo prima di inviarlo.'),
                style: const TextStyle(color: Colors.white70, fontSize: 15),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: TextField(
                  key: const Key('web_generator_first_prompt'),
                  controller: _prompt,
                  readOnly: _busy,
                  minLines: null,
                  maxLines: null,
                  expands: true,
                  maxLength: 1200,
                  textAlignVertical: TextAlignVertical.top,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: tr('Descrivi l’applicazione'),
                    alignLabelWithHint: true,
                    filled: true,
                    fillColor: const Color(0xFF151D29),
                    contentPadding: const EdgeInsets.all(22),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                  ),
                  style: const TextStyle(fontSize: 17, height: 1.5),
                ),
              ),
              const SizedBox(height: 12),
              if (_busy) const LinearProgressIndicator(),
              if (_error case final error?) ...[
                const SizedBox(height: 8),
                Text(tr(error), style: const TextStyle(color: Colors.orangeAccent)),
              ],
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: const Key('web_generator_submit_first_prompt'),
                  onPressed: _busy || _prompt.text.trim().isEmpty
                      ? null
                      : _submit,
                  icon: const Icon(Icons.arrow_forward),
                  label: Text(tr('Genera')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chatBubble(String label, String message, {bool fromUser = false}) {
    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: fromUser
              ? const Color(0xFF23364F)
              : const Color(0xFF222A35),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF9CC7F6),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 5),
            SelectableText(message, style: const TextStyle(height: 1.35)),
          ],
        ),
      ),
    );
  }

  Widget _conversationPane({
    required String Function(String) tr,
    required String? id,
    required Map<String, dynamic>? receipt,
    required String? status,
    required String? verificationStatus,
    required String? verificationLabel,
    required bool canAdvance,
  }) {
    final controller = _chatController;
    final firstPrompt = (_pendingPrompt ?? _prompt.text).trim();

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (firstPrompt.isNotEmpty)
                _chatBubble(tr('Tu'), firstPrompt, fromUser: true),
              for (final turn in _chatTurns)
                _chatBubble(
                  turn.role == ChatRole.user ? tr('Tu') : 'AIVEXUS',
                  turn.content,
                  fromUser: turn.role == ChatRole.user,
                ),
              if (_busy) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
              ],
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    tr(error),
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                ),
              if (controller?.lastError case final error?)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    error,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                ),
              if (status == 'generated' && receipt != null) ...[
                const SizedBox(height: 14),
                Text(receipt['title'] as String,
                    style: Theme.of(context).textTheme.titleMedium),
                for (final item in receipt['requirements'] as List)
                  Text(item as String),
                const SizedBox(height: 12),
                Text(tr('File generati')),
                for (final path in receipt['paths'] as List)
                  SelectableText(path as String),
                const SizedBox(height: 12),
                Text(tr('Modello dichiarato')),
                SelectableText(
                    receipt['provenance']['reportedModel'] as String),
                const SizedBox(height: 8),
                const Text('SHA-256'),
                SelectableText(receipt['sourceSha256'] as String),
                if (verificationLabel != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(tr(verificationLabel)),
                  ),
                ],
                if (id != null)
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (verificationStatus == null || canAdvance)
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => _run(() =>
                                  _readVerification(id, advance: canAdvance)),
                          child: Text(tr(verificationStatus == 'ready'
                              ? 'Verifica applicazione'
                              : 'Aggiorna verifica')),
                        ),
                      if (verificationStatus == 'verified') ...[
                        OutlinedButton(
                          onPressed: _busy ? null : () => _openPreview(id),
                          child: Text(tr('Anteprima')),
                        ),
                        OutlinedButton(
                          onPressed: _busy ? null : () => _openSources(id),
                          child: Text(tr('Sorgenti')),
                        ),
                        Link(
                          uri: _generationResource('download', id),
                          target: LinkTarget.blank,
                          builder: (context, followLink) =>
                              OutlinedButton.icon(
                            onPressed: _busy ? null : followLink,
                            icon: const Icon(Icons.download_outlined),
                            label: Text(tr('Scarica ZIP')),
                          ),
                        ),
                      ],
                    ],
                  ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (id != null && status == null && _pendingPrompt != null)
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: Text(tr('Riprova invio')),
                    ),
                  if (id != null && !_terminalStates.contains(status))
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() => _readStatus(id)),
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
              const SizedBox(height: 18),
              Text(
                tr('La chat permette di discutere il progetto. Le richieste successive non modificano automaticamente i sorgenti già generati.'),
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('web_generator_chat_input'),
                  controller: _chatInput,
                  enabled: controller != null && !controller.isBusy,
                  maxLines: 4,
                  minLines: 1,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: tr('Scrivi all’IA…'),
                    filled: true,
                    fillColor: const Color(0xFF1B2533),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                key: const Key('web_generator_send_chat'),
                tooltip: tr('Invia messaggio'),
                onPressed: controller == null || controller.isBusy
                    ? null
                    : _sendChatMessage,
                icon: controller?.isBusy == true
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    String tr(String label) => WorkshopWebLanguageScope.tr(context, label);
    final id = _generationId;
    final receipt = _receipt;
    final status = receipt?['status'] as String?;
    final state = switch (status) {
      'generating' => 'Generazione in corso',
      'generated' => 'Sorgenti generati',
      'failed' => 'Generazione non riuscita',
      'interrupted' => 'Generazione interrotta',
      _ => null,
    };
    final verificationStatus = _verification?['status'] as String?;
    final verificationLabel = switch (verificationStatus) {
      'checks_missing' =>
        'Crea una nuova generazione per ottenere un piano di verifica.',
      'dispatching' || 'submitted' => 'Verifica in coda o in esecuzione',
      'importing' => 'Importazione dello ZIP in corso',
      'verified' => 'Applicazione verificata',
      'failed' => 'I controlli non sono passati',
      'review_required' => 'Avvio del runner da verificare',
      'unavailable' => 'Il runner non ha completato la verifica',
      _ => null,
    };
    final canAdvance = {'ready', 'dispatching', 'submitted', 'importing'}
        .contains(verificationStatus);
    return Scaffold(
      appBar: AppBar(title: Text(tr('AIVEXUS Studio'))),
      body: SafeArea(
        child: WorkshopWebGeneratorWorkspace(
          showIntro: id == null,
          intro: _firstPromptEditor(tr),
          projectTitle: receipt?['title'] is String
              ? receipt!['title'] as String
              : null,
          generationStatus: state == null ? null : tr(state),
          previewUri: id != null && verificationStatus == 'verified'
              ? _generationResource('preview', id)
              : null,
          onOpenPreview: id != null && verificationStatus == 'verified'
              ? () => _openPreview(id)
              : null,
          onOpenSources: id != null && verificationStatus == 'verified'
              ? () => _openSources(id)
              : null,
          composer: _conversationPane(
            tr: tr,
            id: id,
            receipt: receipt,
            status: status,
            verificationStatus: verificationStatus,
            verificationLabel: verificationLabel,
            canAdvance: canAdvance,
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
