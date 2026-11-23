enum ChangelogCategory { feature, security, performance, fix, other }

class ChangelogEntry {
  final ChangelogCategory category;

  /// The platforms or components the entry is limited to, e.g. `android` and `ios` for `fix(android, ios): ...`.
  final List<String> scopes;

  final bool breaking;
  final String text;

  const ChangelogEntry({required this.category, required this.scopes, required this.breaking, required this.text});
}

class ChangelogRelease {
  final String version;
  final DateTime? date;

  /// Free text between the heading and the entries.
  final String notes;

  final List<ChangelogEntry> entries;

  const ChangelogRelease({required this.version, required this.date, required this.notes, required this.entries});
}

final _heading = RegExp(r'^(\S+)(?: \((.+)\))?');
final _entry = RegExp(r'^(\w+)(?:\((.+?)\))?(!)?: (.+)$');

const _categories = {
  'feat': ChangelogCategory.feature,
  'security': ChangelogCategory.security,
  'perf': ChangelogCategory.performance,
  'fix': ChangelogCategory.fix,
};

List<ChangelogRelease> parseChangelog(String markdown) {
  return [
    for (final section in markdown.split(RegExp(r'^## ', multiLine: true)).skip(1)) _parseRelease(section.trim().split('\n')),
  ];
}

ChangelogRelease _parseRelease(List<String> lines) {
  final heading = _heading.firstMatch(lines.first)!;
  final body = lines.skip(1).where((line) => line.isNotEmpty);
  return ChangelogRelease(
    version: heading.group(1)!,
    date: DateTime.tryParse(heading.group(2) ?? ''),
    notes: body.where((line) => !line.startsWith('- ')).join('\n'),
    entries: [
      for (final line in body)
        if (line.startsWith('- ')) _parseEntry(line.substring(2)),
    ],
  );
}

ChangelogEntry _parseEntry(String entry) {
  final match = _entry.firstMatch(entry);
  if (match == null) {
    return ChangelogEntry(category: ChangelogCategory.other, scopes: const [], breaking: false, text: entry);
  }
  final type = match.group(1)!;
  final category = _categories[type];
  return ChangelogEntry(
    category: category ?? ChangelogCategory.other,
    scopes: [...?match.group(2)?.split(',').map((scope) => scope.trim())],
    breaking: match.group(3) != null,
    // Types without a group of their own (e.g. `i18n:`) keep their prefix, the text is not self-explanatory without it.
    text: category == null ? '$type: ${match.group(4)}' : match.group(4)!,
  );
}

/// Whether [version] is a later release than [other], for dotted numeric versions such as `1.19.0`.
bool isNewerVersion(String version, String other) {
  final [a, b] = [
    for (final v in [version, other]) v.split('.').map((part) => int.tryParse(part) ?? 0).toList(),
  ];
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) {
      return a[i] > b[i];
    }
  }
  return a.length > b.length;
}
