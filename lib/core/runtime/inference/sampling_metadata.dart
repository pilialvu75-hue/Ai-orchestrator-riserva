class SamplingMetadata {
  const SamplingMetadata({
    this.temperature,
    this.topP,
    this.repeatPenalty,
  });

  final double? temperature;
  final double? topP;
  final double? repeatPenalty;

  static final RegExp _metaPattern = RegExp(
    r'<!--META\s+([^>]*?)\s*-->',
    caseSensitive: false,
    dotAll: true,
  );

  static SamplingMetadata fromPrompt(String prompt) {
    final match = _metaPattern.firstMatch(prompt);
    if (match == null) return const SamplingMetadata();

    final payload = match.group(1) ?? '';
    final pairs = <String, String>{};
    for (final token in payload.split(RegExp(r'\s+'))) {
      if (!token.contains('=')) continue;
      final parts = token.split('=');
      if (parts.length < 2) continue;
      final key = parts.first.trim().toLowerCase();
      final value = parts.sublist(1).join('=').trim();
      if (key.isNotEmpty && value.isNotEmpty) {
        pairs[key] = value;
      }
    }

    return SamplingMetadata(
      temperature: _parseDouble(pairs['temp']),
      topP: _parseDouble(pairs['top_p']),
      repeatPenalty: _parseDouble(pairs['repeat_penalty']),
    );
  }

  String stripFrom(String prompt) {
    return prompt.replaceFirst(_metaPattern, '').trimLeft();
  }

  static double? _parseDouble(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return double.tryParse(value.trim());
  }
}
