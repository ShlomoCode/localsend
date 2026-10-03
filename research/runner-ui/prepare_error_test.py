import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / 'packages/localsend_isolates/lib/util/rust.dart'
source = target.read_text()
marker = '      AnyhowException(:final message) => message,'
assert source.count(marker) == 1, 'Pinned error helper changed'
arms = ''.join(f'      rust_http.RsHttpClientError_{kind}(:final field0) => field0,' + chr(10) for kind in ['Reqwest', 'Json', 'Io', 'Other'])
target.write_text(source.replace(marker, arms + marker))
