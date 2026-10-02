import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/changelog_page.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class WhatsNewPage extends StatelessWidget {
  final String version;

  const WhatsNewPage({
    super.key,
    required this.version,
  });

  static WhatsNewPage? fromLastVersion({required String? lastVersion, required String currentVersion}) {
    return lastVersion == currentVersion ? null : WhatsNewPage(version: currentVersion);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.whatsNewPage.title(version: version)),
      ),
      body: Column(
        children: [
          const Expanded(child: ChangelogContent()),
          SafeArea(
            top: false,
            child: ResponsiveListView.single(
              padding: const EdgeInsets.all(15),
              tabletPadding: const EdgeInsets.all(15),
              child: Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () async {
                        await launchUrl(
                          Uri.parse('https://github.com/localsend/localsend/releases/tag/v$version'),
                          mode: LaunchMode.externalApplication,
                        );
                      },
                      icon: const Icon(Icons.open_in_new),
                      label: Text('${t.changelogPage.title} (GitHub)'),
                    ),
                    FilledButton.icon(
                      onPressed: () => context.global.dispatch(NavigateAction.pop()),
                      icon: Icon(Icons.done),
                      label: Text(t.general.done),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
