from pathlib import Path
import sys
file = Path(sys.argv[1]) / 'app/lib/pages/progress_page.dart'
s = file.read_text()
if sys.argv[2] == 'after':
    for source, indent in [('ref.read(serverProvider)?.session', '        '), ('ref.watch(serverProvider)?.session', '    ')]:
        old = indent + 'final receiveSession = ' + source + ';'
        new = indent + 'final receiveSession = switch (' + source + ') {\n' + indent + '  final session? when session.sessionId == widget.sessionId => session,\n' + indent + '  _ => null,\n' + indent + '};'
        assert s.count(old) >= 1
        s = s.replace(old, new, 1)
    old = '        if (!mounted) {'
    new = '        if (!mounted || ModalRoute.of(context)?.isCurrent != true) {'
    assert s.count(old) == 1
    s = s.replace(old, new, 1)
    print('Production 9 added 3 deleted nonblank lines; init/build filtering plus null-session route guard')
file.write_text(s)
