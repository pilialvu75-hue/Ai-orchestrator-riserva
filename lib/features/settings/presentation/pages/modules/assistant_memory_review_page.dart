import 'package:ai_orchestrator/core/memory/assistant_durable_memory.dart';
import 'package:ai_orchestrator/core/memory/assistant_durable_memory_capture_service.dart';
import 'package:flutter/material.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';

/// Explicit, developer-only preview for reviewing local memory proposals.
///
/// No implicit chat capture, telemetry, network access or automatic approvals.
/// The caller must only expose this page on a trusted single-user device;
/// account-aware owner isolation is a separate release gate.
class AssistantMemoryReviewPage extends StatefulWidget {
  const AssistantMemoryReviewPage({
    super.key,
    required this.captureService,
  });

  final AssistantDurableMemoryCaptureService captureService;

  @override
  State<AssistantMemoryReviewPage> createState() =>
      _AssistantMemoryReviewPageState();
}

class _AssistantMemoryReviewPageState extends State<AssistantMemoryReviewPage> {
  final TextEditingController _text = TextEditingController();
  List<AssistantDurableMemoryRecord> _pending =
      const <AssistantDurableMemoryRecord>[];
  bool _loading = true;
  bool _busy = false;
  bool _manualConsent = false;

  String _t(String key) =>
      AppLocalizations(Localizations.localeOf(context)).t('memory_review_$key');

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final pending =
          await widget.captureService.loadReviewablePreferenceCandidates();
      if (!mounted) return;
      setState(() => _pending = pending);
    } on Object catch (_) {
      _message(_t('read_error'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _propose() async {
    if (_busy || !_manualConsent) return;
    setState(() => _busy = true);
    try {
      final ok = await widget.captureService.proposeUserPreferenceCandidate(
        userPrompt: _text.text,
        consentEnabled: true,
      );
      if (!mounted) return;
      if (ok) {
        _text.clear();
        setState(() => _manualConsent = false);
        _message(_t('saved'));
      } else {
        _message(_t('unrecognized'));
      }
      await _refresh();
    } on Object catch (_) {
      _message(_t('save_error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _edit(AssistantDurableMemoryRecord record) {
    // Use the field's own lifecycle instead of disposing a controller while
    // the dialog dismissal animation may still be rendering its last frame.
    var proposed = record.content;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_t('edit_title')),
        content: TextFormField(
          initialValue: record.content,
          onChanged: (value) => proposed = value,
          maxLines: 2,
          maxLength: 110,
          decoration: InputDecoration(
            helperText: _t('allowed'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(_t('cancel')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, proposed.trim()),
            child: Text(_t('continue')),
          ),
        ],
      ),
    );
  }

  Future<void> _resolve(
    AssistantDurableMemoryRecord record, {
    required bool approve,
    String? correctedContent,
  }) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(approve ? _t('confirm_title') : _t('reject_title')),
        content: Text(
          approve
              ? (correctedContent ?? record.content)
              : _t('reject_body'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(_t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(approve ? _t('confirm') : _t('reject')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final changed = await widget.captureService.reviewUserPreferenceCandidate(
        reviewed: record,
        approve: approve,
        userConfirmed: true,
        correctedContent: correctedContent,
      );
      if (!mounted) return;
      _message(changed
          ? (approve ? _t('confirmed') : _t('rejected'))
          : _t('stale'));
      await _refresh();
    } on Object catch (_) {
      _message(_t('operation_error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_t('title'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              _t('intro'),
            ),
            const SizedBox(height: 16),
            Text(
              _t('manual'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _text,
              enabled: !_busy,
              maxLength: 110,
              decoration: InputDecoration(
                labelText: _t('preference'),
                hintText: _t('hint'),
                helperText: _t('italian_only'),
                border: const OutlineInputBorder(),
              ),
            ),
            CheckboxListTile(
              value: _manualConsent,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _manualConsent = v ?? false),
              title: Text(_t('consent')),
              subtitle: Text(
                _t('consent_note'),
              ),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            FilledButton(
              onPressed: _busy || !_manualConsent ? null : _propose,
              child: Text(_t('propose')),
            ),
            const Divider(height: 32),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _t('pending'),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  onPressed: _busy || _loading ? null : _refresh,
                  tooltip: _t('refresh'),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_pending.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_t('empty')),
              )
            else
              for (final record in _pending)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(record.content),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () => _resolve(record, approve: true),
                              child: Text(_t('approve')),
                            ),
                            OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      final corrected = await _edit(record);
                                      if (corrected == null || !mounted) return;
                                      await _resolve(
                                        record,
                                        approve: true,
                                        correctedContent: corrected,
                                      );
                                    },
                              child: Text(_t('edit')),
                            ),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _resolve(record, approve: false),
                              child: Text(_t('reject')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            const SizedBox(height: 12),
            Text(
              _t('footer'),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
