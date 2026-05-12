import 'package:flutter/material.dart';

/// Lightweight, GPU-friendly startup surface.
///
/// Runtime bootstrapping is handled outside this widget; this class remains
/// purely visual and non-blocking.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _entryController;
  late final AnimationController _pulseController;
  late final Animation<double> _entryOpacity;
  late final Animation<double> _entryScale;

  @override
  void initState() {
    super.initState();

    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

    _entryOpacity = CurvedAnimation(
      parent: _entryController,
      curve: Curves.easeOutCubic,
    );
    _entryScale = Tween<double>(begin: 0.94, end: 1).animate(
      CurvedAnimation(parent: _entryController, curve: Curves.easeOutCubic),
    );

    _entryController.forward();
  }

  @override
  void dispose() {
    _entryController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: AnimatedBuilder(
        animation: Listenable.merge([_entryController, _pulseController]),
        builder: (context, _) {
          final pulse = _pulseController.value;
          final glowOpacity = 0.16 + (pulse * 0.16);
          final breathingScale = 0.985 + (pulse * 0.03);
          final ambientOpacity = 0.12 + (pulse * 0.08);

          return Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment(-1 + (pulse * 0.2), -1),
                    end: Alignment(1, 1 - (pulse * 0.2)),
                    colors: [
                      const Color(0xFF0A0E15),
                      const Color(0xFF111A2B).withOpacity(0.94),
                      const Color(0xFF0D0D0D),
                    ],
                  ),
                ),
              ),
              Opacity(
                opacity: ambientOpacity,
                child: const _TerminalAtmosphere(),
              ),
              Center(
                child: FadeTransition(
                  opacity: _entryOpacity,
                  child: ScaleTransition(
                    scale: _entryScale,
                    child: Transform.scale(
                      scale: breathingScale,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 76,
                            height: 76,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  const Color(0xFF8AB4F8)
                                      .withOpacity(glowOpacity),
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
                              letterSpacing: 0.45,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Initializing local intelligence...',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.54),
                              fontSize: 13,
                              fontFamily: 'monospace',
                              letterSpacing: 0.2,
                            ),
                          ),
                        ],
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
              color: const Color(0xFF8AB4F8).withOpacity(0.16 - (index * 0.02)),
            ),
          ),
        ),
      ),
    );
  }
}
