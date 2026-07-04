import 'dart:async';

import 'package:ai_orchestrator/core/runtime/inference/inference_response.dart';
import 'package:ai_orchestrator/core/runtime/inference/runtime_event_log.dart';

class ToolInterceptorTransformer extends StreamTransformerBase<InferenceResponse, InferenceResponse> {
  static const String _searchTagStart = '<search>';
  static const String _searchTagEnd = '</search>';

  @override
  Stream<InferenceResponse> bind(Stream<InferenceResponse> stream) {
    late StreamController<InferenceResponse> controller;
    StreamSubscription<InferenceResponse>? subscription;

    controller = StreamController<InferenceResponse>(
      onListen: () {
        final buffer = StringBuffer();

        subscription = stream.listen(
          (response) {
            // Le risposte di errore o gli stati terminali non necessitano di ispezione
            if (response.isError) {
              controller.add(response);
              return;
            }

            final textChunk = response.text ?? '';
            if (textChunk.isEmpty) {
              controller.add(response);
              return;
            }

            buffer.write(textChunk);
            final currentText = buffer.toString();

            // 1. Verifica di cattura completa: Il tag è stato aperto, scritto e chiuso?
            final RegExp completeMatchRegex = RegExp(r'<search>(.*?)</search>', dotAll: true);
            final match = completeMatchRegex.firstMatch(currentText);
            
            if (match != null) {
              final query = match.group(1)?.trim() ?? '';
              
              RuntimeEventLog.instance.emit(
                '[TOOL_INTERCEPTOR] target=search status=extracted query="$query"',
              );
              
              // Emettiamo il messaggio speciale formattato e chiudiamo la sottoscrizione
              controller.add(
                InferenceResponse.token(
                  text: '\n\n🔍 Sto cercando su Internet: \'$query\'...',
                  model: response.model,
                ),
              );
              
              subscription?.cancel();
              controller.close();
              return;
            }

            // 2. Verifica di ritenzione sicura: Siamo nel mezzo di un tag aperto?
            if (currentText.contains(_searchTagStart)) {
              // Tratteniamo i token nel buffer finché non arriva la chiusura </search>
              return;
            }

            // 3. Verifica di ritenzione parziale: I token stanno formando l'apertura del tag?
            if (_hasPartialSearchTag(currentText)) {
              // Il frammento potrebbe completarsi in <search> al prossimo ciclo
              return;
            }

            // 4. Scarico sicuro: Nessun tag in vista. Emettiamo il contenuto del buffer.
            if (currentText.isNotEmpty) {
              // Re-impacchettiamo il testo (che potrebbe includere token trattenuti per un falso allarme)
              controller.add(
                InferenceResponse.token(
                  text: currentText,
                  model: response.model,
                ),
              );
              buffer.clear();
            }
          },
          onError: controller.addError,
          onDone: () {
            // Scarico finale di sicurezza se lo stream si chiude con testo residuo non-tag
            if (buffer.isNotEmpty && !controller.isClosed) {
              controller.add(
                InferenceResponse.token(
                  text: buffer.toString(),
                  model: 'unknown',
                ),
              );
            }
            if (!controller.isClosed) {
              controller.close();
            }
          },
          cancelOnError: false,
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () => subscription?.cancel(),
    );

    return controller.stream;
  }

  /// Controlla se la fine del testo corrente corrisponde a un prefisso del tag di apertura.
  /// Previene la stampa accidentale a schermo di frammenti come "<sear"
  bool _hasPartialSearchTag(String text) {
    for (int i = 1; i <= _searchTagStart.length; i++) {
      if (text.endsWith(_searchTagStart.substring(0, i))) {
        return true;
      }
    }
    return false;
  }
}
