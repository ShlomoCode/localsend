from pathlib import Path
import sys

root = Path(sys.argv[1])
file = root / 'app/lib/provider/network/send_provider.dart'
source = file.read_text()
old = '    final selectedFiles = files.map((file) => (id: _uuid.v4(), file: file)).toList();'
new = '''    final currentFiles = <CrossFile>[];
    for (final file in files) {
      final path = file.path;
      if (file.bytes == null && path != null && !path.startsWith('content://')) {
        try {
          currentFiles.add(file.copyWith(size: await File(path).length()));
          continue;
        } on FileSystemException {}
      }
      currentFiles.add(file);
    }
    final selectedFiles = currentFiles.map((file) => (id: _uuid.v4(), file: file)).toList();'''
assert source.count(old) == 1, 'Wrong source pin or patch already applied'
assert "import 'dart:io';" not in source
source = source.replace("import 'dart:convert';", "import 'dart:convert';\nimport 'dart:io';").replace(old, new)
file.write_text(source)
print('Applied stale-size patch to', file)
