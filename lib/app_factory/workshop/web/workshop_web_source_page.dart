import 'package:flutter/material.dart';

class WorkshopWebSourcePage extends StatefulWidget {
  const WorkshopWebSourcePage({super.key, required this.files});

  final Future<Map<String, String>> files;

  @override
  State<WorkshopWebSourcePage> createState() => _WorkshopWebSourcePageState();
}

class _WorkshopWebSourcePageState extends State<WorkshopWebSourcePage> {
  String? _selectedPath;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Sorgenti verificati')),
        body: FutureBuilder<Map<String, String>>(
          future: widget.files,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(child: Text('Sorgenti non disponibili.'));
            }
            final files = snapshot.data;
            if (files == null) {
              return const Center(child: CircularProgressIndicator());
            }
            final path = _selectedPath ?? 'index.html';
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButton<String>(
                    value: path,
                    isExpanded: true,
                    onChanged: (value) => setState(() => _selectedPath = value),
                    items: [
                      for (final file in files.keys)
                        DropdownMenuItem(value: file, child: Text(file)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      child: SelectableText(
                        files[path]!,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
}
