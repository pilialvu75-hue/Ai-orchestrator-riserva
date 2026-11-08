import 'package:aivexus_running_total/aivexus_running_total.dart';

/// Actual Cantiere-side consumer of the independently generated Library package.
/// Run from the isolated Dart consumer project created by CI; no app dependency
/// or automatic installation is introduced.
void main() {
  final input = <int>[7, -2, 11];
  final output = runningTotals(input);
  if (output.join(',') != '7,5,16') {
    throw StateError('Unexpected Library running total: $output');
  }
  if (input.join(',') != '7,-2,11') {
    throw StateError('Library module mutated Cantiere input: $input');
  }
  var immutable = false;
  try {
    output.add(1);
  } on UnsupportedError {
    immutable = true;
  }
  if (!immutable) {
    throw StateError('Library result must be immutable');
  }
  print('[CANTIERE_LIBRARY] consumer=generated-dart status=PASS output=$output');
}
