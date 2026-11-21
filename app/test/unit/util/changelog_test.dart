import 'package:localsend_app/util/changelog.dart';
import 'package:test/test.dart';

void main() {
  test('parseChangelog splits releases into categorized entries', () {
    final releases = parseChangelog('''
## 1.19.0 (2026-11-21)

- feat(cli)!: replace `--file` with the `send` command (@otanim)
- fix(android, ios): keep file names (@Tienisto)
- i18n: add Kyrgyz (@nidara-duo)

## 1.18.1

Android+iOS only hotfix update.

- Initial Release
''');

    expect(releases.map((r) => r.version), ['1.19.0', '1.18.1']);
    expect(releases[0].date, DateTime(2026, 11, 21));
    expect(releases[1].date, null);
    expect(releases[1].notes, 'Android+iOS only hotfix update.');

    final [feature, fix, i18n] = releases[0].entries;
    expect(feature.category, ChangelogCategory.feature);
    expect(feature.scopes, ['cli']);
    expect(feature.breaking, true);
    expect(feature.text, 'replace `--file` with the `send` command (@otanim)');
    expect(fix.category, ChangelogCategory.fix);
    expect(fix.scopes, ['android', 'ios']);
    expect(fix.breaking, false);
    expect(i18n.category, ChangelogCategory.other);
    expect(i18n.text, 'i18n: add Kyrgyz (@nidara-duo)');
    expect(releases[1].entries.single.text, 'Initial Release');
  });

  test('compareVersions orders numerically', () {
    expect(compareVersions('1.10.0', '1.9.2'), greaterThan(0));
    expect(compareVersions('1.19.0', '1.19.0'), 0);
    expect(compareVersions('1.18.2', '1.19.0'), lessThan(0));
    expect(compareVersions('1.19.0-beta', '1.19.0'), null);
  });
}
