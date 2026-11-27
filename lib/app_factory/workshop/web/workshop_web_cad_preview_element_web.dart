// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:html' as html;

void setCadPreviewProject(Object element, String projectId) =>
    (element as html.Element).setAttribute('project-id', projectId);
