// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

void downloadWorkshopJson(List<int> bytes, String filename) {
  final blob = html.Blob([Uint8List.fromList(bytes)], 'application/json');
  final url = html.Url.createObjectUrlFromBlob(blob);
  final link = html.AnchorElement(href: url)..download = filename;
  html.document.body!.append(link);
  link.click();
  link.remove();
  Future<void>.delayed(const Duration(seconds: 10), () {
    html.Url.revokeObjectUrl(url);
  });
}
