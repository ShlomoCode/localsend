import 'dart:convert';
import 'dart:io';

// Runs source extracted from the pinned production Linux branch. Only its
// platform environment/executable dependencies are injected for fixtures.
Future<void> main(List<String> args) async {
  if (args.length != 3) throw ArgumentError('baseline source, patched source, output directory required');
  final output = Directory(args[2]).absolute..createSync(recursive: true);
  final manifest = <Map<String, dynamic>>[];
  final names = ['plain.AppImage', 'space name.AppImage', 'quote"name.AppImage', r'back\slash.AppImage', r'dollar$name.AppImage', 'back`tick.AppImage', 'percent%f.AppImage', 'line\nbreak.AppImage', 'tab\tname.AppImage'];
  for (var version = 0; version < 2; version++) {
    final source = File(args[version]).readAsStringSync();
    final start = source.indexOf('      case TargetPlatform.linux:');
    final end = source.indexOf('      case TargetPlatform.macOS:', start);
    var linux = source.substring(start + '      case TargetPlatform.linux:'.length, end);
    linux = linux.replaceAll('Platform.environment', 'environment').replaceAll('Platform.resolvedExecutable', 'resolvedExecutable');
    final linuxPathStart = source.indexOf('String _getLinuxFilePath(');
    var linuxPath = source.substring(linuxPathStart, source.indexOf('\n}', linuxPathStart) + 2);
    linuxPath = linuxPath.replaceAll('Platform.environment', 'environment');
    var quote = '';
    if (source.contains('String _quoteDesktopExecutable(')) {
      final quoteStart = source.indexOf('String _quoteDesktopExecutable(');
      quote = source.substring(quoteStart, source.indexOf('\n}', quoteStart) + 2);
    }
    var index = 0;
    for (final name in names) {
      for (final useAppImage in [true, false]) {
      for (final hidden in [false, true]) {
        final dir = Directory('${output.path}/v$version-case${index++}')..createSync(recursive: true);
        final appImage = File('${dir.path}/$name');
        appImage.writeAsStringSync('#!/usr/bin/env python3\nimport json, os, sys\nwith open(os.environ["PACKAGING_RECORD"], "w") as f: json.dump(sys.argv[1:], f)\n');
        await Process.run('chmod', ['+x', appImage.path]);
        final mount = Directory('${dir.path}/temporary-mount')..createSync();
        final resolved = useAppImage ? '${mount.path}/localsend_app' : appImage.path;
        if (useAppImage) File(resolved).writeAsStringSync('placeholder temporary executable');
        final env = {'HOME': '${dir.path}/home', if (useAppImage) 'APPIMAGE': appImage.path};
        final worker = File('${dir.path}/worker.dart');
        worker.writeAsStringSync("import 'dart:io';\nconst startHiddenFlag = '--hidden';\nfinal environment = <String,String>${jsonEncode(env).replaceAll(r'$', r'\$')};\nconst resolvedExecutable = ${jsonEncode(resolved).replaceAll(r'$', r'\$')};\nclass PackageInfoFixture { final appName = 'LocalSend'; final packageName = 'localsend_app'; }\nFuture<bool> generate() async { final packageInfo = PackageInfoFixture(); final startHidden = $hidden; $linux }\n$linuxPath\n$quote\nFuture<void> main() async { if (!await generate()) throw StateError('generation failed'); }\n");
        final run = await Process.run(Platform.resolvedExecutable, [worker.path]);
        if (run.exitCode != 0) throw StateError('${run.stdout}\n${run.stderr}');
        mount.deleteSync(recursive: true);
        manifest.add({'version': version == 0 ? 'before' : 'after', 'name': name, 'hidden': hidden, 'use_appimage': useAppImage, 'desktop': '${env['HOME']}/.config/autostart/localsend_app.desktop', 'record': '${dir.path}/receipt.json', 'appimage': appImage.path, 'temporary_mount_exists': mount.existsSync(), 'expected_argv': hidden ? ['--hidden'] : <String>[]});
      }
      }
    }
  }
  File('${output.path}/manifest.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
  stdout.writeln('Generated ${manifest.length} actual-branch desktop files');
}
