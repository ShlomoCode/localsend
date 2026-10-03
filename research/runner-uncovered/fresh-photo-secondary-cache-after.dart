import 'dart:io';
import 'dart:isolate';
class RootIsolateToken {}
class BackgroundIsolateBinaryMessenger { static void ensureInitialized(RootIsolateToken token) {} }
class Level { static const ALL = 1; }
void initLogger(int level) {}
class Logger { void warning(String message) {} void info(String message) {} }
final _logger = Logger();
enum TargetPlatform { iOS, android }
bool checkPlatform(List<TargetPlatform> platforms) => platforms.contains(TargetPlatform.iOS);
class FilePicker { static Future<void> clearTemporaryFiles() async {} }
class PhotoManager { static Future<void> clearFileCache() async {} }
String fixtureCache = '';
Future<Directory> getTemporaryDirectory() async => Directory(fixtureCache);
class PathProviderFoundation { Future<String?> getContainerPath({required String appGroupIdentifier}) async => null; }
extension FileName on String { String get fileName => split('/').last; }
Future<void> _clear(RootIsolateToken token) async {
  initLogger(Level.ALL);
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);

  final futures = (
    FilePicker.clearTemporaryFiles(),
    PhotoManager.clearFileCache(),
    checkPlatform([TargetPlatform.iOS, TargetPlatform.android])
        ? getTemporaryDirectory().then((cacheDir) async {
            await for (final event in cacheDir.list()) {
              if (event is File) {
                await event.delete().then((_) {}).catchError((error) {
                  _logger.warning('Failed to delete file: $error');
                });
              }
            }
          })
        : Future.value(),
    checkPlatform([TargetPlatform.iOS])
        ? PathProviderFoundation()
              .getContainerPath(
                appGroupIdentifier: 'group.org.localsend.localsendApp',
              )
              .then((directoryPath) async {
                if (directoryPath == null) {
                  _logger.warning('Failed to get app group directory');
                  return;
                }

                final directory = Directory(directoryPath);

                // delete contents of the directory (only files, not directories)
                await for (final entry in directory.list(recursive: false, followLinks: false)) {
                  if (entry is File && !entry.path.fileName.startsWith('.')) {
                    _logger.info('Deleting ${entry.path}');
                    entry.deleteSync();
                  }
                }
              })
        : Future.value(),
  ).wait;

  try {
    await futures;
  } catch (e) {
    _logger.warning('Failed to clear cache: $e');
  }
}

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('cache-cleanup-isolate-');
  try {
    final cache = Directory('${root.path}/Library/Caches');
    await cache.create(recursive: true);
    final documents = File('${root.path}/Documents/keep.jpg');
    await documents.parent.create(recursive: true);
    await documents.writeAsBytes([1, 2, 3]);
    for (var i = 0; i < 100; i++) {
      await File('${cache.path}/failed-receive-$i.jpg').writeAsBytes([255,216,255,217]);
    }
    final unrelatedDirectory = Directory('${cache.path}/unrelated-plugin');
    await unrelatedDirectory.create();
    final directoryMarker = File('${unrelatedDirectory.path}/keep.txt');
    await directoryMarker.writeAsString('keep');
    final cachePath = cache.path;
    await Isolate.run(() async {
      fixtureCache = cachePath;
      await _clear(RootIsolateToken());
    });
    final remaining = await cache.list().where((entry) => entry is File).length;
    if (remaining != 0) throw StateError('$remaining cache files remain after cleanup completion');
    if (!await documents.exists()) throw StateError('Documents removed');
    if (!await directoryMarker.exists()) throw StateError('non-root plugin cache removed');
    print('PASS all100failed-transfer cache files removed before isolate completion; Documents and unrelated directory retained');
  } finally { await root.delete(recursive: true); }
}
