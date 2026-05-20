import 'package:flutter/material.dart';

/// Lightweight, GPU-friendly startup surface inspired by DevDuo IDE.
///
/// Displays a smooth fade + slide-up entry (≤ 900 ms), an IDE-style blinking
/// cursor on the status line, and a thin progress bar — all non-blocking.
/// Runtime bootstrapping happens outside this widget.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // Entry: fade + slide-up, completes within 900ms (well under 1.5s cap).
  late final AnimationController _entryController;
  // Cursor blink: 550ms half-period, repeats while splash is visible.
  late final AnimationController _cursorController;
  // Progress bar: fills to ~65% over 1400ms, then holds.
  late final AnimationController _progressController;

  late final Animation<double> _entryOpacity;
  late final Animation<double> _entrySlide;
  late final Animation<double> _progressValue;

  @override
  void initState() {
    super.initState();

    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _cursorController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    )..repeat(reverse: true);
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    _entryOpacity = CurvedAnimation(
      parent: _entryController,
      curve: Curves.easeOutCubic,
    );
    // Slides content up from 14 px below its final position.
    _entrySlide = Tween<double>(begin: 14.0, end: 0.0).animate(
      CurvedAnimation(parent: _entryController, curve: Curves.easeOutCubic),
    );
    // Fills to 65% — the remaining fraction stays visible while loading.
    _progressValue = Tween<double>(begin: 0.0, end: 0.65).animate(
      CurvedAnimation(parent: _progressController, curve: Curves.easeOut),
    );

    _entryController.forward();
    _progressController.forward();
  }

  @override
  void dispose() {
    _entryController.dispose();
    _cursorController.dispose();
    _progressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: AnimatedBuilder(
        animation:
            Listenable.merge([_entryController, _cursorController, _progressController]),
        builder: (context, _) {
          // Cursor blinks by toggling opacity on the controller's mid-value.
          final cursorOn = _cursorController.value > 0.5;

          return Stack(
            fit: StackFit.expand,
            children: [
              // ── Static background gradient ─────────────────────────────
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment(-1, -1),
                    end: Alignment(1, 1),
                    colors: [
                      Color(0xFF0A0E15),
                      Color(0xFF111A2B),
                      Color(0xFF0D0D0D),
                    ],
                  ),
                ),
              ),
              // ── Ambient terminal lines ─────────────────────────────────
              const Opacity(
                opacity: 0.14,
                child: _TerminalAtmosphere(),
              ),
              // ── Main content: fade + slide-up ──────────────────────────
              Center(
                child: FadeTransition(
                  opacity: _entryOpacity,
                  child: Transform.translate(
                    offset: Offset(0, _entrySlide.value),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Icon with soft glow ring
                        Container(
                          width: 72,
                          height: 72,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                Color(0x288AB4F8),
                                Colors.transparent,
                              ],
                            ),
                          ),
                          child: const Icon(
                            Icons.auto_awesome,
                            color: Color(0xFF8AB4F8),
                            size: 38,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'AI Orchestrator',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.45,
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Status text with blinking IDE cursor
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Initializing local intelligence...',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.54),
                                fontSize: 13,
                                fontFamily: 'monospace',
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(width: 2),
                            Opacity(
                              opacity: cursorOn ? 0.85 : 0.0,
                              child: const Text(
                                '▋',
                                style: TextStyle(
                                  color: Color(0xFF8AB4F8),
                                  fontSize: 13,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),
                        // Thin IDE-style progress bar (2 dp height)
                        SizedBox(
                          width: 176,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: _progressValue.value,
                              backgroundColor: const Color(0x148AB4F8),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                Color(0xFF8AB4F8),
                              ),
                              minHeight: 2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // ── Bottom tagline ─────────────────────────────────────────
              Positioned(
                bottom: 28,
                left: 0,
                right: 0,
                child: FadeTransition(
                  opacity: _entryOpacity,
                  child: const Center(
                    child: Text(
                      'Offline · Private · On-device',
                      style: TextStyle(
                        color: Color(0x428AB4F8),
                        fontSize: 11,
                        letterSpacing: 0.6,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TerminalAtmosphere extends StatelessWidget {
  const _TerminalAtmosphere();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 240,
        height: 180,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            6,
            (index) => Container(
              margin: const EdgeInsets.symmetric(vertical: 5),
              width: 220 - (index * 18),
              height: 1,
              color: const Color(0xFF8AB4F8)
                  .withValues(alpha: 0.14 - (index * 0.02)),
            ),
          ),
        ),
      ),
    );
  }
}
