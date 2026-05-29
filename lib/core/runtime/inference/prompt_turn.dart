import 'package:equatable/equatable.dart';

class PromptTurn extends Equatable {
  const PromptTurn({
    required this.role,
    required this.content,
  });

  final String role;
  final String content;

  PromptTurn copyWith({
    String? role,
    String? content,
  }) {
    return PromptTurn(
      role: role ?? this.role,
      content: content ?? this.content,
    );
  }

  @override
  List<Object?> get props => [role, content];
}
