import 'package:equatable/equatable.dart';

/// Domain entity representing a request to an AI model.
///
/// This is a core contract shared by the orchestration layer and all
/// AI provider implementations (cloud and local).
class AiRequest extends Equatable {
  const AiRequest({
    required this.prompt,
    this.systemPrompt,
    this.temperature = 0.7,
    this.maxTokens = 2048,
  });

  final String prompt;
  final String? systemPrompt;
  final double temperature;
  final int maxTokens;

  @override
  List<Object?> get props => [prompt, systemPrompt, temperature, maxTokens];
}
