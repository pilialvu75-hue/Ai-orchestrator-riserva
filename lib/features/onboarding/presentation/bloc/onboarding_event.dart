import 'package:equatable/equatable.dart';

abstract class OnboardingEvent extends Equatable {
  const OnboardingEvent();

  @override
  List<Object?> get props => [];
}

class SaveUserInfoEvent extends OnboardingEvent {
  const SaveUserInfoEvent({required this.name, required this.birthDate});

  final String name;
  final String birthDate;

  @override
  List<Object?> get props => [name, birthDate];
}

class StartOnboardingEvent extends OnboardingEvent {
  const StartOnboardingEvent();
}

class CheckModelUpdatesEvent extends OnboardingEvent {
  const CheckModelUpdatesEvent();
}

class CompleteOnboardingEvent extends OnboardingEvent {
  const CompleteOnboardingEvent();
}
