import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_orchestrator/core/config/app/app_constants.dart';
import 'package:ai_orchestrator/features/onboarding/data/datasources/model_registry_datasource.dart';
import 'package:ai_orchestrator/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:ai_orchestrator/features/onboarding/presentation/bloc/onboarding_state.dart';

class OnboardingBloc extends Bloc<OnboardingEvent, OnboardingState> {
  OnboardingBloc({required this.modelRegistryDataSource})
      : super(const OnboardingInitial()) {
    on<SaveUserInfoEvent>(_onSaveUserInfo);
    on<StartOnboardingEvent>(_onStart);
    on<CheckModelUpdatesEvent>(_onCheckUpdates);
    on<CompleteOnboardingEvent>(_onComplete);
  }

  final ModelRegistryDataSource modelRegistryDataSource;

  Future<void> _onSaveUserInfo(
      SaveUserInfoEvent event, Emitter<OnboardingState> emit) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefUserName, event.name);
    await prefs.setString(AppConstants.prefUserBirthDate, event.birthDate);
    add(const StartOnboardingEvent());
  }

  Future<void> _onStart(
      StartOnboardingEvent event, Emitter<OnboardingState> emit) async {
    emit(const OnboardingLoading());
    add(const CheckModelUpdatesEvent());
  }

  Future<void> _onCheckUpdates(
      CheckModelUpdatesEvent event, Emitter<OnboardingState> emit) async {
    emit(const OnboardingLoading());
    try {
      final models = await modelRegistryDataSource.getModelUpdates();
      emit(OnboardingReady(models));
    } catch (_) {
      emit(const OnboardingReady([]));
    }
  }

  Future<void> _onComplete(
      CompleteOnboardingEvent event, Emitter<OnboardingState> emit) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefOnboardingDone, true);
    emit(const OnboardingComplete());
  }
}
