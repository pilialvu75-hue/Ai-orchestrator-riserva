import 'package:flutter/material.dart';

import 'package:ai_orchestrator/app/app_shell.dart';

/// Lightweight startup splash that shows a brief, elegant animation before
/// transitioning to the main [AppShell].
///
/// Design goals (TASK 4):
///  - Fast: total duration ≤ 2 seconds
///  - Elegant: logo fade-in + subtle scale, then fade-out
///  - Minimal: no heavy assets, pure widget animation
///  - Smooth: always replaces itself with AppShell (no back-stack entry)
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );

    // Fade in over 0–40 % of the total duration, then hold, then fade out.
    _opacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 30),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 30),
    ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    // Subtle scale: 0.88 → 1.0 during the fade-in phase.
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.88, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 30,
      ),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 70),
    ]).animate(_controller);

    _controller.forward().then((_) => _navigateToShell());
  }

  void _navigateToShell() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => const AppShell(),
        transitionsBuilder: (_, animation, __, child) => FadeTransition(
          opacity: animation,
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Opacity(
              opacity: _opacity.value,
              child: Transform.scale(
                scale: _scale.value,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Icon with subtle gradient glow
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            const Color(0xFF8AB4F8).withOpacity(0.25),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      child: const Icon(
                        Icons.auto_awesome,
                        color: Color(0xFF8AB4F8),
                        size: 40,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'AI Orchestrator',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Your AI Operating System',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.45),
                        fontSize: 13,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
