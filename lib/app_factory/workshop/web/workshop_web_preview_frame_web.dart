// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:html' as html;

import 'package:flutter/widgets.dart';

class WorkshopWebPreviewFrame extends StatelessWidget {
  const WorkshopWebPreviewFrame({super.key, required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) => HtmlElementView.fromTagName(
        tagName: 'iframe',
        onElementCreated: (element) {
          final frame = element as html.IFrameElement;
          frame
            ..setAttribute('sandbox', 'allow-scripts')
            ..setAttribute('referrerpolicy', 'no-referrer')
            ..setAttribute('title', 'Anteprima applicazione AIVEXUS')
            ..style.border = '0'
            ..style.width = '100%'
            ..style.height = '100%'
            ..src = uri.toString();
        },
      );
}
