import 'package:ai_orchestrator/core/runtime/inference/sampling_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SamplingMetadata', () {
    test('parses META tags from prompt payloads', () {
      const prompt =
          '<!--META temp=0.2 top_p=0.85 repeat_penalty=1.15 -->\nUser: hello';

      final metadata = SamplingMetadata.fromPrompt(prompt);

      expect(metadata.temperature, 0.2);
      expect(metadata.topP, 0.85);
      expect(metadata.repeatPenalty, 1.15);
    });

    test('strips META tags before runtime execution', () {
      const prompt =
          '<!--META temp=0.2 top_p=0.85 repeat_penalty=1.15 -->\nUser: hello';

      final metadata = SamplingMetadata.fromPrompt(prompt);

      expect(metadata.stripFrom(prompt), 'User: hello');
    });
  });
}
