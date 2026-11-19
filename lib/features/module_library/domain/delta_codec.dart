// Vendored from AI-Orchestrator-Module-Library delta_codec@0.1.0.
// Original Qwen-generated Dart implementation, internal development use only.
// Upstream payload SHA256: d2291bd30d18a5f98dd17099d7086d6c811bff7a205be4a3a9ad72949cbe5ada
class DeltaCodec {
  static List<int> encodeDeltas(List<int> samples) {
    if (samples.isEmpty) return [];
    List<int> encoded = [samples[0]];
    for (int i = 1; i < samples.length; i++) {
      encoded.add(samples[i] - samples[i - 1]);
    }
    return encoded;
  }

  static List<int> decodeDeltas(List<int> deltas) {
    if (deltas.isEmpty) return [];
    List<int> decoded = [deltas[0]];
    for (int i = 1; i < deltas.length; i++) {
      decoded.add(decoded[i - 1] + deltas[i]);
    }
    return decoded;
  }
}

List<int> encodeDeltas(List<int> samples) => DeltaCodec.encodeDeltas(samples);
List<int> decodeDeltas(List<int> deltas) => DeltaCodec.decodeDeltas(deltas);
