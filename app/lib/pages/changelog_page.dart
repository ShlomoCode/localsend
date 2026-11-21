import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:localsend_app/gen/assets.gen.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/changelog.dart';
import 'package:localsend_app/util/system_date_time_formatter.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';

class ChangelogPage extends StatefulWidget {
  const ChangelogPage();

  @override
  State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage> {
  late final Future<List<ChangelogRelease>> _releases = rootBundle.loadString(Assets.changelog).then(parseChangelog);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.changelogPage.title),
      ),
      body: FutureBuilder(
        future: _releases,
        builder: (context, snapshot) {
          final releases = snapshot.data;
          if (releases == null) {
            return Container();
          }
          return ResponsiveListView.builder(
            padding: const EdgeInsets.all(15),
            itemCount: releases.length,
            itemBuilder: (context, index) => _ReleaseCard(release: releases[index], initiallyExpanded: index == 0),
          );
        },
      ),
    );
  }
}

class _ReleaseCard extends StatelessWidget {
  final ChangelogRelease release;
  final bool initiallyExpanded;

  const _ReleaseCard({required this.release, required this.initiallyExpanded});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = release.date;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        // Restores the expansion when the card is scrolled out of view and back.
        key: PageStorageKey(release.version),
        initiallyExpanded: initiallyExpanded,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(release.version, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        subtitle: date == null ? null : Text(SystemDateTimeFormatter.date(context, date)),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          if (release.notes.isNotEmpty) _ltr(Text(release.notes)),
          for (final category in ChangelogCategory.values)
            if (release.entries.any((entry) => entry.category == category)) ...[
              _CategoryHeader(category: category),
              for (final entry in release.entries)
                if (entry.category == category) _ltr(_EntryRow(entry: entry)),
            ],
        ],
      ),
    );
  }
}

/// The changelog is only available in English, so its text is laid out left-to-right in every locale.
Widget _ltr(Widget child) => Directionality(textDirection: TextDirection.ltr, child: child);

class _CategoryHeader extends StatelessWidget {
  final ChangelogCategory category;

  const _CategoryHeader({required this.category});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, label) = switch (category) {
      ChangelogCategory.feature => (Icons.auto_awesome, t.changelogPage.categories.feature),
      ChangelogCategory.security => (Icons.shield_outlined, t.changelogPage.categories.security),
      ChangelogCategory.performance => (Icons.speed, t.changelogPage.categories.performance),
      ChangelogCategory.fix => (Icons.bug_report_outlined, t.changelogPage.categories.fix),
      ChangelogCategory.other => (Icons.more_horiz, t.changelogPage.categories.other),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 2),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(label, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
        ],
      ),
    );
  }
}

const _scopeLabels = {
  'android': 'Android',
  'ios': 'iOS',
  'macos': 'macOS',
  'mac': 'macOS',
  'windows': 'Windows',
  'linux': 'Linux',
  'cli': 'CLI',
  'desktop': 'Desktop',
  'mobile': 'Mobile',
};

class _EntryRow extends StatelessWidget {
  final ChangelogEntry entry;

  const _EntryRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final segments = entry.text.split('`');
    // An unpaired backtick is not inline code.
    final hasInlineCode = segments.length.isOdd;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('•'),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  for (final scope in entry.scopes)
                    _badge(
                      label: _scopeLabels[scope.toLowerCase()] ?? scope,
                      backgroundColor: colorScheme.secondaryContainer,
                      foregroundColor: colorScheme.onSecondaryContainer,
                    ),
                  if (entry.breaking)
                    _badge(
                      label: t.changelogPage.breaking,
                      backgroundColor: colorScheme.errorContainer,
                      foregroundColor: colorScheme.onErrorContainer,
                    ),
                  if (hasInlineCode)
                    for (final (index, segment) in segments.indexed)
                      TextSpan(
                        text: segment,
                        style: index.isOdd ? const TextStyle(fontFamily: 'monospace') : null,
                      )
                  else
                    TextSpan(text: entry.text),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

InlineSpan _badge({required String label, required Color backgroundColor, required Color foregroundColor}) {
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(label, style: TextStyle(color: foregroundColor, fontSize: 12)),
    ),
  );
}
