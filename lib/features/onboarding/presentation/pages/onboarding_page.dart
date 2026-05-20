import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:ai_orchestrator/app/app_shell.dart';
import 'package:ai_orchestrator/core/runtime/app_localizations.dart';
import 'package:ai_orchestrator/features/local_ai/domain/entities/ai_model.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_bloc.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_event.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/bloc/model_download_state.dart';
import 'package:ai_orchestrator/features/local_ai/presentation/widgets/model_download_card.dart';
import 'package:ai_orchestrator/core/ai/model_manager.dart';
import 'package:ai_orchestrator/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:ai_orchestrator/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:ai_orchestrator/features/onboarding/presentation/bloc/onboarding_state.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _pageController = PageController();
  int _currentPage = 0;

  // User-info form (Step 0)
  final _nameController = TextEditingController();
  final _birthDateController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _pageController.dispose();
    _nameController.dispose();
    _birthDateController.dispose();
    super.dispose();
  }

  void _submitUserInfo() {
    if (_formKey.currentState?.validate() ?? false) {
      context.read<OnboardingBloc>().add(SaveUserInfoEvent(
            name: _nameController.text.trim(),
            birthDate: _birthDateController.text.trim(),
          ));
      _pageController.nextPage(
          duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
    }
  }

  void _goToNext() {
    if (_currentPage == 1) {
      _pageController.nextPage(
          duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
      context.read<OnboardingBloc>().add(const StartOnboardingEvent());
    } else {
      context.read<OnboardingBloc>().add(const CompleteOnboardingEvent());
    }
  }

  Future<void> _pickBirthDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(1990),
      firstDate: DateTime(1920),
      lastDate: DateTime.now(),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF8AB4F8),
            surface: Color(0xFF1A1A1A),
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      _birthDateController.text =
          '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<OnboardingBloc, OnboardingState>(
      listener: (context, state) {
        if (state is OnboardingReady) {
          _pageController.animateToPage(
            3,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeInOut,
          );
        }
        if (state is OnboardingComplete) {
          Navigator.of(context).pushReplacement(
              MaterialPageRoute<void>(builder: (_) => const AppShell()));
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D0D),
        body: SafeArea(
          child: PageView(
            controller: _pageController,
            physics: const NeverScrollableScrollPhysics(),
            onPageChanged: (i) => setState(() => _currentPage = i),
            children: [
              // Step 0 – User info
              _UserInfoPage(
                formKey: _formKey,
                nameController: _nameController,
                birthDateController: _birthDateController,
                onPickDate: _pickBirthDate,
                onContinue: _submitUserInfo,
              ),
              // Step 1 – Welcome
              _WelcomePage(onContinue: _goToNext),
              // Step 2 – Checking updates
              const _CheckingUpdatesPage(),
              // Step 3 – Model selection
              _ModelsPage(onContinue: _goToNext),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Step 0: User info ────────────────────────────────────────────────────────

class _UserInfoPage extends StatelessWidget {
  const _UserInfoPage({
    required this.formKey,
    required this.nameController,
    required this.birthDateController,
    required this.onPickDate,
    required this.onContinue,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController nameController;
  final TextEditingController birthDateController;
  final VoidCallback onPickDate;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Form(
        key: formKey,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.person_outline_rounded,
                color: Color(0xFF8AB4F8), size: 64),
            const SizedBox(height: 24),
            Text(
              l10n.t('tell_us_about_you'),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.t('personalize_experience'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 14,
                  height: 1.5),
            ),
            const SizedBox(height: 40),
            // Name field
            TextFormField(
              controller: nameController,
              style: const TextStyle(color: Colors.white),
              decoration: _inputDecoration(l10n.t('your_name'), Icons.badge_outlined),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? l10n.t('name_required') : null,
            ),
            const SizedBox(height: 16),
            // Birth date field
            TextFormField(
              controller: birthDateController,
              style: const TextStyle(color: Colors.white),
              readOnly: true,
              onTap: onPickDate,
              decoration: _inputDecoration(
                  l10n.t('dob_ddmmyyyy'), Icons.cake_outlined),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? l10n.t('dob_required') : null,
            ),
            const SizedBox(height: 40),
            _ContinueButton(onPressed: onContinue, label: l10n.t('continue')),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white38),
      prefixIcon: Icon(icon, color: const Color(0xFF8AB4F8), size: 20),
      filled: true,
      fillColor: const Color(0xFF1A1A1A),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF8AB4F8), width: 1.5),
      ),
      errorStyle: const TextStyle(color: Colors.redAccent),
    );
  }
}

// ── Step 1: Welcome ──────────────────────────────────────────────────────────

class _WelcomePage extends StatelessWidget {
  const _WelcomePage({required this.onContinue});

  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.auto_awesome, color: Color(0xFF8AB4F8), size: 72),
          const SizedBox(height: 24),
          Text(l10n.t('ai_orchestrator'),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5)),
          const SizedBox(height: 12),
          Text(
            l10n.t('welcome_subtitle'),
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55), fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 48),
          _ContinueButton(onPressed: onContinue, label: l10n.t('get_started')),
        ],
      ),
    );
  }
}

// ── Step 2: Checking updates ─────────────────────────────────────────────────

class _CheckingUpdatesPage extends StatelessWidget {
  const _CheckingUpdatesPage();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: Color(0xFF8AB4F8)),
          const SizedBox(height: 24),
          Text(l10n.t('checking_updates'),
              style: const TextStyle(color: Colors.white70, fontSize: 15)),
        ],
      ),
    );
  }
}

// ── Step 3: Model selection ───────────────────────────────────────────────────

class _ModelsPage extends StatelessWidget {
  const _ModelsPage({required this.onContinue});

  final VoidCallback onContinue;

  static const _modelManager = ModelManager();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocConsumer<ModelDownloadBloc, ModelDownloadState>(
      listener: (context, state) {
        if (state is ModelDownloadError) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.message),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
        if (state is ModelsLoaded && state.downloadErrorMessage != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.downloadErrorMessage!),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      },
      builder: (context, state) {
        final isLoading =
            state is ModelDownloadInitial || state is ModelDownloadLoading;
        final models =
            state is ModelsLoaded ? state.models : <AiModel>[];
        final selectedModelId =
            state is ModelsLoaded ? state.selectedModelId : null;
        final downloadProgress =
            state is ModelsLoaded ? state.downloadProgress : <String, double>{};
        final recommendedId = _modelManager.getRecommendedModelId(models);

        final canContinue = selectedModelId != null &&
            models.any((m) =>
                m.id == selectedModelId &&
                m.isDownloaded &&
                m.validationStatus != ModelValidationStatus.invalidModel);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 48),
              Text(
                l10n.t('choose_model'),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                '${l10n.t('download_offline_model')}\n'
                '${l10n.t('recommended_for_device')} ${_modelManager.platformModelLabel}',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5), fontSize: 14),
              ),
              const SizedBox(height: 24),
              if (isLoading)
                const Expanded(
                  child: Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFF8AB4F8)),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: models.length,
                    itemBuilder: (_, i) {
                      final model = models[i];
                      return ModelDownloadCard(
                        model: model,
                        isSelected: selectedModelId == model.id,
                        isRecommended: model.id == recommendedId,
                        downloadProgress: downloadProgress[model.id],
                        onDownload: () => context
                            .read<ModelDownloadBloc>()
                            .add(StartModelDownload(model: model)),
                        onCancel: () => context
                            .read<ModelDownloadBloc>()
                            .add(CancelModelDownload(modelId: model.id)),
                        onSelect: () => context
                            .read<ModelDownloadBloc>()
                            .add(SelectActiveModel(modelId: model.id)),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 16),
              _ContinueButton(
                onPressed: canContinue ? onContinue : null,
                label: l10n.t('continue'),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }
}

class _ContinueButton extends StatelessWidget {
  const _ContinueButton({required this.onPressed, required this.label});

  final VoidCallback? onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF8AB4F8),
          foregroundColor: const Color(0xFF0D0D0D),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(26)),
        ),
        child: Text(label,
            style: const TextStyle(
                fontWeight: FontWeight.w600, fontSize: 16)),
      ),
    );
  }
}
