enum ChangelogCategory { feature, security, performance, fix, other }

class ChangelogEntry {
  final ChangelogCategory category;

  /// The platforms or components the entry is limited to, e.g. `android` and `ios` for `fix(android, ios): ...`.
  final List<String> scopes;

  final bool breaking;
  final String text;

  const ChangelogEntry({
    required this.category,
    required this.scopes,
    required this.breaking,
    required this.text,
  });
}

class ChangelogRelease {
  final String version;
  final DateTime? date;

  /// Free text between the heading and the entries.
  final String notes;

  final List<ChangelogEntry> entries;

  const ChangelogRelease({
    required this.version,
    required this.date,
    required this.notes,
    required this.entries,
  });
}

final _heading = RegExp(r'^## (\S+)(?: \((\d{4}-\d{2}-\d{2})\))?');
final _entry = RegExp(r'^- (\w+)(?:\(([^)]*)\))?(!)?: (.+)$');

const _categories = {
  'feat': ChangelogCategory.feature,
  'security': ChangelogCategory.security,
  'perf': ChangelogCategory.performance,
  'fix': ChangelogCategory.fix,
};

List<ChangelogRelease> parseChangelog(String markdown) {
  final releases = <ChangelogRelease>[];
  String? version;
  DateTime? date;
  var notes = <String>[];
  var entries = <ChangelogEntry>[];

  void finishRelease() {
    if (version != null) {
      releases.add(ChangelogRelease(version: version, date: date, notes: notes.join('\n'), entries: entries));
    }
  }

  for (final rawLine in markdown.split('\n')) {
    final line = rawLine.trimRight();
    final heading = _heading.firstMatch(line);
    if (heading != null) {
      finishRelease();
      version = heading.group(1);
      date = switch (heading.group(2)) {
        final value? => DateTime.tryParse(value),
        null => null,
      };
      notes = [];
      entries = [];
    } else if (line.startsWith('- ')) {
      entries.add(_parseEntry(line));
    } else if (line.isNotEmpty) {
      notes.add(line);
    }
  }
  finishRelease();

  return releases;
}

ChangelogEntry _parseEntry(String line) {
  final match = _entry.firstMatch(line);
  final category = _categories[match?.group(1)];
  if (match == null || category == null) {
    // Keep the prefix of types without a group of their own (e.g. `i18n:`), the text is not self-explanatory without it.
    return ChangelogEntry(category: ChangelogCategory.other, scopes: const [], breaking: false, text: line.substring(2));
  }

  return ChangelogEntry(
    category: category,
    scopes: [
      for (final scope in (match.group(2) ?? '').split(','))
        if (scope.trim().isNotEmpty) scope.trim(),
    ],
    breaking: match.group(3) != null,
    text: match.group(4)!,
  );
}

/// Compares dotted numeric versions such as `1.19.0`. Returns `null` if one of them has another format.
int? compareVersions(String a, String b) {
  final partsA = _versionParts(a);
  final partsB = _versionParts(b);
  if (partsA == null || partsB == null) {
    return null;
  }

  for (var i = 0; i < partsA.length || i < partsB.length; i++) {
    final diff = (i < partsA.length ? partsA[i] : 0).compareTo(i < partsB.length ? partsB[i] : 0);
    if (diff != 0) {
      return diff;
    }
  }
  return 0;
}

List<int>? _versionParts(String version) {
  final parts = version.split('.').map(int.tryParse).toList();
  return parts.contains(null) ? null : parts.cast<int>();
}
