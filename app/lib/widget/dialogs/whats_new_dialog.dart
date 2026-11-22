import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/changelog_page.dart';
import 'package:localsend_app/util/changelog.dart';
import 'package:localsend_app/util/system_date_time_formatter.dart';
import 'package:routerino/routerino.dart';

/// Shows the changes of [release] after the app has been updated to it.
class WhatsNewDialog extends StatelessWidget {
  final ChangelogRelease release;

  const WhatsNewDialog({required this.release, super.key});

  static Future<void> open(BuildContext context, ChangelogRelease release) async {
    final openChangelog = await showDialog<bool>(
      context: context,
      builder: (_) => WhatsNewDialog(release: release),
    );
    if (openChangelog == true && context.mounted) {
      await context.push(() => const ChangelogPage());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = release.date;
    // Styled like a release card of the changelog page, so the same content looks the same in both places.
    return AlertDialog(
      backgroundColor: theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow,
      shape: theme.cardTheme.shape ?? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      titlePadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      actionsPadding: const EdgeInsets.all(16),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.whatsNewPage.title(version: release.version),
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          if (date != null)
            Text(
              SystemDateTimeFormatter.date(context, date),
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: ChangelogReleaseBody(release: release),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t.changelogPage.title),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.general.close),
        ),
      ],
    );
  }
}
