import 'package:flutter/material.dart';

import 'workshop_web_cad_preview_element_stub.dart'
    if (dart.library.html) 'workshop_web_cad_preview_element_web.dart';

class WorkshopWebCadPreviewPage extends StatelessWidget {
  const WorkshopWebCadPreviewPage({
    super.key,
    required this.projectId,
    required this.description,
  });

  final String projectId;
  final String description;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Studio Stampa 3D')),
        body: HtmlElementView.fromTagName(
          tagName: 'aivexus-stl-preview',
          onElementCreated: (element) =>
              setCadPreviewProject(element, projectId, description),
        ),
      );
}