import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/core/runtime/inference/hybrid_cloud_disclosure_consent.dart';
import 'package:flutter/material.dart';

/// One review for ONE exact Cloud disclosure, regardless of provider.
///
/// This widget is source-only until a trusted Chat request assembler wires
/// [ask] into HybridCloudDisclosureConsent.authorizeForDispatch.
/// It never sends data, switches providers, or saves preferences itself.
class HybridCloudConsentReviewDialog extends StatefulWidget {
  const HybridCloudConsentReviewDialog({
    super.key,
    required this.review,
  });

  final HybridCloudConsentReview review;

  static Future<Map<HybridDisclosureScope, HybridCloudConsentChoice>> ask(
    BuildContext context,
    HybridCloudConsentReview review,
  ) async {
    final result = await showDialog<
        Map<HybridDisclosureScope, HybridCloudConsentChoice>>(
      context: context,
      barrierDismissible: true,
      builder: (_) => HybridCloudConsentReviewDialog(review: review),
    );
    // Dismissal, Back and errors never become consent.
    return result ?? <HybridDisclosureScope, HybridCloudConsentChoice>{};
  }

  @override
  State<HybridCloudConsentReviewDialog> createState() =>
      _HybridCloudConsentReviewDialogState();
}

class _HybridCloudConsentReviewDialogState
    extends State<HybridCloudConsentReviewDialog> {
  late final Map<HybridDisclosureScope, HybridCloudConsentChoice> _choices;

  @override
  void initState() {
    super.initState();
    // Nothing is ever pre-approved on opening the window.
    _choices = <HybridDisclosureScope, HybridCloudConsentChoice>{
      for (final scope in widget.review.needsConsent)
        scope: HybridCloudConsentChoice.denyOnce,
    };
  }

  String _t(String key) => context.l10n.t('cloud_review_' + key);
  String _p(String key) => context.l10n.t('cloud_permission_' + key);

  String _label(HybridDisclosureScope scope) =>
      _p('origin_' + scope.origin.name) +
      ' · ' + _p('level_' + scope.sensitivity.name);

  String _choiceName(HybridCloudConsentChoice choice) => switch (choice) {
        HybridCloudConsentChoice.allowOnce => _t('once'),
        HybridCloudConsentChoice.allowAlways => _p('allow'),
        HybridCloudConsentChoice.allowAndAskNextTime => _t('now_ask'),
        HybridCloudConsentChoice.denyOnce => _t('deny_once'),
        HybridCloudConsentChoice.neverShare => _p('deny'),
      };

  Future<void> _submit() async {
    if (_choices.values.contains(HybridCloudConsentChoice.allowAlways)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(_p('confirm_title')),
          content: Text(_p('confirm_body')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(_p('cancel')),
            ),
            FilledButton(
              key: const Key('review-confirm-persistent'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(_p('confirm')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(
      Map<HybridDisclosureScope, HybridCloudConsentChoice>.unmodifiable(
        _choices,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.review.disclosure;
    return AlertDialog(
      title: Text(_t('title')),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_t('intro')),
              const SizedBox(height: 12),
              SelectableText(_p('provider') + ': ' + data.providerId),
              SelectableText(_t('account') + ': ' + data.accountId),
              SelectableText(_t('reason') + ': ' + data.purpose),
              const SizedBox(height: 14),
              Text(_t('categories'),
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              for (final scope in widget.review.needsConsent) ...[
                Text(_label(scope)),
                const SizedBox(height: 6),
                DropdownButtonFormField<HybridCloudConsentChoice>(
                  key: Key('review-choice-' + scope.origin.name + '-' +
                      scope.sensitivity.name),
                  isExpanded: true,
                  value: _choices[scope],
                  items: HybridCloudConsentChoice.values
                      .where((value) =>
                          value != HybridCloudConsentChoice.allowAlways ||
                          scope.sensitivity !=
                              HybridDisclosureSensitivity.unknown)
                      .map((value) => DropdownMenuItem(
                            value: value,
                            child: Text(_choiceName(value)),
                          ))
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _choices[scope] = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
              ],
              Text(_t('preview'),
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Text(_t('preview_hint'),
                  style: Theme.of(context).textTheme.bodySmall),
              for (var i = 0; i < data.segments.length; i++)
                ExpansionTile(
                  key: Key('review-section-' + i.toString()),
                  title: Text(_label(data.segments[i].scope)),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: SelectableText(data.segments[i].text),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              Text(_t('single_request'),
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('review-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_p('cancel')),
        ),
        FilledButton(
          key: const Key('review-apply'),
          onPressed: _submit,
          child: Text(_t('continue')),
        ),
      ],
    );
  }
}
