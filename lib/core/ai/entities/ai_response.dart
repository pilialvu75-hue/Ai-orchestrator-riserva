import 'package:equatable/equatable.dart';

/// Domain entity representing a response from an AI model.
///
/// This is a core contract shared by the orchestration layer and all
/// AI provider implementations (cloud and local).
class AiResponse extends Equatable {
  const AiResponse({
    required this.text,
    required this.model,
    required this.tokensUsed,
    required this.timestamp,
  });

  /// The generated text content.
  final String text;

  /// The AI model identifier that produced this response (e.g. "gpt-4o").
  final String model;

  /// Total tokens consumed by the request + response.
  final int tokensUsed;

  /// UTC epoch milliseconds when the response was received.
  final int timestamp;

  @override
  List<Object?> get props => [text, model, tokensUsed, timestamp];
}
