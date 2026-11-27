import 'package:flutter/material.dart';

class WorkshopWebCadPreviewPage extends StatelessWidget {
  const WorkshopWebCadPreviewPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Anteprima STL')),
        body: HtmlElementView.fromTagName(tagName: 'aivexus-stl-preview'),
      );
}