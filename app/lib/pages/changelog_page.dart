import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:localsend_app/gen/assets.gen.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/changelog.dart';
import 'package:localsend_app/util/system_date_time_formatter.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';

class ChangelogPage extends StatelessWidget {
  const ChangelogPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.changelogPage.title),
      ),
      body: FutureBuilder(
        future: rootBundle.loadString(Assets.changelog), // ignore: discarded_futures
        builder: (context, data) {
          if (!data.hasData) {
            return Container();
          }
          final releases = parseChangelog(data.data!);
          return ResponsiveListView.builder(
            padding: const EdgeInsets.all(15),
            itemCount: releases.length,
            itemBuilder: (context, index) {
              final release = releases[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                clipBehavior: Clip.antiAlias,
                child: ExpansionTile(
                  // Restores the expansion when the card is scrolled out of view and back.
                  key: PageStorageKey(release.version),
                  initiallyExpanded: index == 0,
                  shape: const Border(),
                  collapsedShape: const Border(),
                  title: ChangelogReleaseTitle(release: release, title: release.version),
                  expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [ChangelogReleaseBody(release: release)],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class ChangelogReleaseTitle extends StatelessWidget {
  final ChangelogRelease release;
  final String title;

  const ChangelogReleaseTitle({required this.release, required this.title, super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final date = release.date;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        if (date != null) Text(SystemDateTimeFormatter.date(context, date), style: textTheme.bodyMedium),
      ],
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

class ChangelogReleaseBody extends StatelessWidget {
  final ChangelogRelease release;

  const ChangelogReleaseBody({required this.release, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // 'monospace' is a generic family only on Android and Linux.
    final codeStyle = TextStyle(
      fontFamily: switch (theme.platform) {
        TargetPlatform.iOS || TargetPlatform.macOS => 'Menlo',
        TargetPlatform.windows => 'Consolas',
        _ => 'monospace',
      },
    );
    final breakingColor = theme.brightness == Brightness.dark ? Colors.orange.shade200 : Colors.orange.shade900;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (release.notes.isNotEmpty) _ltr(Text(release.notes)),
        for (final (category, icon, label) in [
          (ChangelogCategory.feature, Icons.auto_awesome, t.changelogPage.categories.feature),
          (ChangelogCategory.security, Icons.shield_outlined, t.changelogPage.categories.security),
          (ChangelogCategory.performance, Icons.speed, t.changelogPage.categories.performance),
          (ChangelogCategory.fix, Icons.bug_report_outlined, t.changelogPage.categories.fix),
          (ChangelogCategory.other, Icons.more_horiz, t.changelogPage.categories.other),
        ])
          if (release.entries.any((entry) => entry.category == category)) ...[
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 2),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: colors.primary),
                  const SizedBox(width: 8),
                  Text(label, style: theme.textTheme.titleSmall?.copyWith(color: colors.primary)),
                ],
              ),
            ),
            for (final entry in release.entries)
              if (entry.category == category)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _ltr(
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('•'),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                for (final scope in entry.scopes)
                                  _badge(_scopeLabels[scope.toLowerCase()] ?? scope, colors.secondaryContainer, colors.onSecondaryContainer),
                                if (entry.breaking) _badge(t.changelogPage.breaking, breakingColor.withValues(alpha: 0.15), breakingColor),
                                ..._spansWithInlineCode(entry.text, codeStyle),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
      ],
    );
  }
}

/// The changelog is only available in English, so its text is laid out left-to-right in every locale.
Widget _ltr(Widget child) => Directionality(textDirection: TextDirection.ltr, child: child);

InlineSpan _badge(String label, Color backgroundColor, Color foregroundColor) {
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: backgroundColor, borderRadius: BorderRadius.circular(5)),
      child: Text(label, style: TextStyle(color: foregroundColor, fontSize: 12)),
    ),
  );
}

List<InlineSpan> _spansWithInlineCode(String text, TextStyle codeStyle) {
  return [
    for (final (index, segment) in text.split('`').indexed) TextSpan(text: segment, style: index.isOdd ? codeStyle : null),
  ];
}
