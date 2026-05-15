import 'package:ai_orchestrator/core/tokenizer/tokenizer_runtime.dart';
import 'package:ai_orchestrator/core/tokenizer/tokenizer_state.dart';
import 'package:ai_orchestrator/core/tokenizer/tokenizer_validator.dart';

class TokenizerService {
  TokenizerService({
    TokenizerRuntime? runtime,
    TokenizerValidator? validator,
  })  : _runtime = runtime ?? TokenizerRuntime(),
        _validator = validator ?? TokenizerValidator();

  final TokenizerRuntime _runtime;
  final TokenizerValidator _validator;

  Future<bool> initialize(String modelPath) =>
      _runtime.initialize(modelPath);

  Future<bool> validateForModel(String modelPath) =>
      _validator.validateForModel(_runtime, modelPath);

  bool get isReady => _runtime.isReady;

  TokenizerState get currentState => _runtime.currentState;

  Stream<TokenizerState> get stateStream => _runtime.stateStream;

  void dispose() => _runtime.reset();
}
