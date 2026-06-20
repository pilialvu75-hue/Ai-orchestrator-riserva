import 'package:ai_orchestrator/core/runtime/inference/ffi/llama_native_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('adapts thread counts to the local CPU budget', () {
    expect(LlamaNativeDefaults.threadCountForCores(4), 2);
    expect(LlamaNativeDefaults.threadCountForCores(6), 4);
    expect(LlamaNativeDefaults.threadCountForCores(8), 6);
    expect(LlamaNativeDefaults.nThreads, inInclusiveRange(2, 6));
    expect(LlamaNativeDefaults.nThreadsBatch, LlamaNativeDefaults.nThreads);
  });
}
