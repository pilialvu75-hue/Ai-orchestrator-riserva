import 'package:equatable/equatable.dart';
import 'package:ai_orchestrator/features/onboarding/domain/entities/model_update_info.dart';

abstract class OnboardingState extends Equatable {
  const OnboardingState();

  @override
  List<Object?> get props => [];
}

class OnboardingInitial extends OnboardingState {
  const OnboardingInitial();
}

class OnboardingLoading extends OnboardingState {
  const OnboardingLoading();
}

class OnboardingReady extends OnboardingState {
  const OnboardingReady(this.models);

  final List<ModelUpdateInfo> models;

  @override
  List<Object?> get props => [models];
}

class OnboardingComplete extends OnboardingState {
  const OnboardingComplete();
}
