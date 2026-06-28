import 'package:flutter/material.dart';

class DebugLabOverlay extends StatelessWidget {
  final VoidCallback onToggleMetrics;
  final ValueChanged<double> onTextScaleChanged;
  final ValueChanged<double> onFontSizeChanged;
  final double currentTextScale;
  final double currentFontSize;
  final VoidCallback onClose;

  const DebugLabOverlay({
    super.key,
    required this.onToggleMetrics,
    required this.onTextScaleChanged,
    required this.onFontSizeChanged,
    required this.currentTextScale,
    required this.currentFontSize,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 80.0, // Posizionato sopra la barra di input
      left: 16.0,
      right: 16.0,
      child: Card(
        elevation: 8.0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14.0),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header del Debug Lab
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.bug_report_outlined, color: Colors.orangeAccent, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'AI-Orchestrator Developer Lab',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onClose,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const Divider(height: 20),

              // Controllo 1: Toggle Monitor Metriche
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.av_timer_outlined),
                title: const Text('Overlay Metriche Hardware', style: TextStyle(fontSize: 13)),
                trailing: TextButton(
                  onPressed: onToggleMetrics,
                  child: const Text('Toggle'),
                ),
              ),

              // Controllo 2: Text Scale dell'intera Viewport (Slider)
              const Text('Fattore di scala testo generale:', style: TextStyle(fontSize: 12, color: Colors.grey)),
              Row(
                children: [
                  const Icon(Icons.text_fields_outlined, size: 16),
                  Expanded(
                    child: Slider(
                      value: currentTextScale,
                      min: 0.8,
                      max: 1.6,
                      divisions: 4,
                      label: currentTextScale.toStringAsFixed(1),
                      onChanged: onTextScaleChanged,
                    ),
                  ),
                  Text('${currentTextScale.toStringAsFixed(1)}x', style: const TextStyle(fontSize: 12)),
                ],
              ),

              // Controllo 3: Dimensione Font Assistente (Slider)
              const Text('Dimensione carattere Assistente:', style: TextStyle(fontSize: 12, color: Colors.grey)),
              Row(
                children: [
                  const Icon(Icons.format_size_outlined, size: 16),
                  Expanded(
                    child: Slider(
                      value: currentFontSize,
                      min: 12.0,
                      max: 20.0,
                      divisions: 8,
                      label: '${currentFontSize.toStringAsFixed(0)}pt',
                      onChanged: onFontSizeChanged,
                    ),
                  ),
                  Text('${currentFontSize.toStringAsFixed(0)}pt', style: const TextStyle(fontSize: 12)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
