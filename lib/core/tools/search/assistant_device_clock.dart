/// Answers only complete, simple Italian device-clock questions.
/// Mixed requests, external locations and quoted text remain ordinary chat.
abstract final class AssistantDeviceClock {
  static String? answer(String prompt, DateTime now) {
    final value = prompt.trim().toLowerCase().replaceAll(RegExp(r'[?!.]+$'), '').trim();
    final time = RegExp(r"^(?:che ore sono|che ora è|che ora e'|dimmi l'ora|ora attuale)$").hasMatch(value);
    final date = RegExp(r"^(?:che giorno è oggi|che giorno e' oggi|qual è la data di oggi|qual e' la data di oggi|data di oggi)$").hasMatch(value);
    final both = RegExp(r"^(?:la )?data e (?:l')?ora(?: di oggi| attuali)?$").hasMatch(value);
    if (!time && !date && !both) return null;
    String two(int n) => n.toString().padLeft(2, '0');
    final day = '${two(now.day)}/${two(now.month)}/${now.year}';
    final hour = '${two(now.hour)}:${two(now.minute)}';
    final offset = now.timeZoneOffset;
    final zone = 'UTC${offset.isNegative ? '-' : '+'}${two(offset.abs().inHours)}:${two(offset.abs().inMinutes % 60)}';
    final result = both ? '$day, $hour ($zone)' : time ? '$hour ($zone)' : day;
    return '$result — orologio del dispositivo.';
  }
}
