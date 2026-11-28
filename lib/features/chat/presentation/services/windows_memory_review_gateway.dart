import 'dart:async';

import 'package:ai_orchestrator/core/runtime/inference/cancellation_token.dart';
import 'package:ai_orchestrator/core/runtime/inference/windows_memory_review.dart';
import 'package:flutter/material.dart';

/// Visible chat only; never persists consent and never alters model selection.
class WindowsMemoryReviewGateway {
  static final instance = WindowsMemoryReviewGateway();
  final _hosts = <Object, ({BuildContext context, String Function() session,
      bool Function() sending})>{};
  ({Object host, NavigatorState navigator, DialogRoute<WindowsMemoryChoice> route})? _pending;

  Object bind({required BuildContext context,
      required String Function() activeSessionId, required bool Function() isSending}) {
    final id = Object();
    _hosts[id] = (context: context, session: activeSessionId, sending: isSending);
    return id;
  }

  void unbind(Object id) {
    _hosts.remove(id);
    invalidate(id);
  }

  void invalidate(Object? id) {
    final pending = _pending;
    if (pending == null || !identical(pending.host, id)) return;
    _pending = null;
    if (pending.navigator.mounted && pending.route.isActive) {
      pending.navigator.removeRoute(pending.route);
    }
  }

  Future<WindowsMemoryChoice> ask(String sessionId, WindowsMemoryReview review,
      CancellationToken cancellation) async {
    if (_pending != null || cancellation.isCancelled) return WindowsMemoryChoice.cancel;
    final matches = _hosts.entries.where((entry) {
      final host = entry.value;
      return host.context.mounted && host.session() == sessionId &&
          host.sending() && (ModalRoute.of(host.context)?.isCurrent ?? false);
    }).toList();
    // Multiple workspaces with the same session ID cannot approve each other.
    if (matches.length != 1) return WindowsMemoryChoice.cancel;
    final entry = matches.single;
    final host = entry.value;
    final navigator = Navigator.maybeOf(host.context, rootNavigator: true);
    if (navigator == null || !navigator.mounted) return WindowsMemoryChoice.cancel;
    final route = DialogRoute<WindowsMemoryChoice>(
      context: host.context,
      builder: (context) => WindowsMemoryReviewDialog(review: review),
    );
    final pending = (host: entry.key, navigator: navigator, route: route);
    _pending = pending;
    void dismiss() {
      if (_pending?.route == route) invalidate(entry.key);
    }
    cancellation.onCancel(dismiss);
    final timer = Timer(const Duration(seconds: 45), dismiss);
    try {
      final choice = await navigator.push(route);
      if (_pending?.route != route || cancellation.isCancelled ||
          !host.context.mounted || !_hosts.containsKey(entry.key) ||
          host.session() != sessionId || !host.sending()) {
        return WindowsMemoryChoice.cancel;
      }
      return choice ?? WindowsMemoryChoice.cancel;
    } catch (_) {
      return WindowsMemoryChoice.cancel;
    } finally {
      timer.cancel();
      dismiss();
    }
  }
}

class WindowsMemoryReviewDialog extends StatelessWidget {
  const WindowsMemoryReviewDialog({super.key, required this.review});
  final WindowsMemoryReview review;

  @override
  Widget build(BuildContext context) {
    final language = Localizations.localeOf(context).languageCode;
    final strings = switch (language) {
      'it' => ['Memoria potenzialmente insufficiente',
        'Il modello resta selezionato. Una stima prudenziale non rientra nella memoria disponibile.',
        'RAM libera', 'VRAM libera rilevata', 'File modello',
        'La protezione RAM rimane attiva. Un tentativo può essere lento o interrompersi.',
        'Annulla', 'Riprova', 'Prova comunque', 'Parametri ridotti',
        'Al momento non esiste un piano con memoria verificata sufficiente. Libera memoria e riprova.'],
      'fr' => ['Mémoire potentiellement insuffisante',
        'Le modèle reste sélectionné. La marge de sécurité estimée est insuffisante.',
        'RAM libre', 'VRAM libre détectée', 'Fichier du modèle',
        'La protection RAM reste active. Un essai peut être lent ou interrompu.',
        'Annuler', 'Réessayer', 'Essayer quand même', 'Paramètres réduits',
        'Aucun plan avec suffisamment de mémoire vérifiée. Libérez de la mémoire et réessayez.'],
      'es' => ['Memoria posiblemente insuficiente',
        'El modelo sigue seleccionado. El margen de seguridad estimado es insuficiente.',
        'RAM libre', 'VRAM libre detectada', 'Archivo del modelo',
        'La protección RAM sigue activa. El intento puede ser lento o interrumpirse.',
        'Cancelar', 'Reintentar', 'Intentar de todos modos', 'Parámetros reducidos',
        'No hay un plan con suficiente memoria verificada. Libera memoria y vuelve a intentarlo.'],
      _ => ['Potentially insufficient memory',
        'The model remains selected. The estimated safety margin does not fit.',
        'Free RAM', 'Detected free VRAM', 'Model file',
        'RAM protection remains active. An attempt may be slow or interrupted.',
        'Cancel', 'Retry', 'Try anyway', 'Reduced settings',
        'No plan has sufficient verified memory. Free memory and retry.'],
    };
    final layoutWarning = switch (language) {
      'it' => 'La struttura GGUF non è stata verificata dal calcolatore GPU. Questo non dimostra che la memoria sia insufficiente o che il modello sia incompatibile.',
      'fr' => 'La structure GGUF n’a pas été vérifiée par le calculateur GPU. Cela ne prouve pas un manque de mémoire ni une incompatibilité.',
      'es' => 'El calculador GPU no pudo verificar la estructura GGUF. Esto no demuestra falta de memoria ni incompatibilidad.',
      _ => 'The GPU planner could not verify the GGUF layout. This does not establish insufficient memory or model incompatibility.',
    };
    String gib(int? bytes) => bytes == null ? '—' :
        '${(bytes / 1073741824).toStringAsFixed(2)} GiB';
    void choose(WindowsMemoryChoice choice) => Navigator.of(context).pop(choice);
    return AlertDialog(
      title: Text(strings[0]),
      content: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(review.layoutVerified ? strings[1] : layoutWarning),
          const SizedBox(height: 12),
          Text('${strings[2]}: ${gib(review.availableRamBytes)}'),
          Text('${strings[3]}: ${gib(review.availableVramBytes)}'),
          Text('${strings[4]}: ${gib(review.modelBytes)}'),
          const SizedBox(height: 12),
          Text(strings[5]),
          if (!review.canAttempt && review.layoutVerified) Text(strings[10]),
        ],
      )),
      actions: [
        TextButton(onPressed: () => choose(WindowsMemoryChoice.cancel), child: Text(strings[6])),
        TextButton(onPressed: () => choose(WindowsMemoryChoice.retry), child: Text(strings[7])),
        TextButton(onPressed: review.canAttempt ? () => choose(WindowsMemoryChoice.reduced) : null,
            child: Text(strings[9])),
        FilledButton(onPressed: review.canAttempt ? () => choose(WindowsMemoryChoice.tryAnyway) : null,
            child: Text(strings[8])),
      ],
    );
  }
}
