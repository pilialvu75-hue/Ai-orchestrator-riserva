import 'package:flutter/material.dart';

import 'workshop_web_cad_preview_element_stub.dart'
    if (dart.library.html) 'workshop_web_cad_preview_element_web.dart';

class WorkshopWebCadPreviewPage extends StatelessWidget {
  const WorkshopWebCadPreviewPage({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Anteprima STL')),
        body: HtmlElementView.fromTagName(
          tagName: 'aivexus-stl-preview',
          onElementCreated: (element) => setCadPreviewProject(element, projectId),
        ),
      );
}