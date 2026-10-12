import 'dart:io';

import 'package:path/path.dart' as p;

class AutoStartSnapshot {
  final bool? enabled;
  final bool hidden;
  final bool canModify;

  const AutoStartSnapshot({required this.enabled, required this.hidden, required this.canModify});
}

const _unavailable = AutoStartSnapshot(enabled: null, hidden: false, canModify: false);
const _flatpakId = 'org.localsend.localsend_app';
const _flatpakCommand = ['/usr/bin/flatpak', 'run', '--command=/app/localsend_app', _flatpakId];

/// Owns only LocalSend's registration, not arbitrary desktop launch commands.
class LinuxAutoStart {
  final String? filePath;
  final String appName;
  final List<String> command;
  final String legacyExecutable;
  final bool flatpak;
  final bool readable;
  final bool writable;

  const LinuxAutoStart._(this.filePath, this.appName, this.command, this.legacyExecutable, this.flatpak, this.readable, this.writable);

  factory LinuxAutoStart.resolve({
    required Map<String, String> environment,
    required String executable,
    required String packageName,
    required String appName,
    String? flatpakInfo,
  }) {
    bool absolute(String? value) => value != null && value.isNotEmpty && p.posix.isAbsolute(value) && !value.contains('\u0000');
    final xdg = environment['XDG_CONFIG_HOME'];
    final home = environment['HOME'];
    final config = absolute(xdg) ? p.posix.normalize(xdg!) : (absolute(home) ? p.posix.join(home!, '.config') : null);
    bool readable = config != null;
    bool writable = readable;
    if (flatpakInfo != null) {
      final info = _parseGroups(flatpakInfo);
      readable = false;
      writable = false;
      if (info?['Application']?['name'] == _flatpakId && config != null) {
        final hostConfig = info?['Instance']?['host-config-dir'];
        final sameConfig = absolute(hostConfig) && p.posix.normalize(hostConfig!) == config;
        final scopes = info?['Context']?['filesystems']?.split(';') ?? <String>[];
        bool denied = false;
        final modes = <String>{};
        for (final scope in scopes.where((value) => value.isNotEmpty)) {
          final parts = scope.split(':');
          if (parts.length > 2) continue;
          final location = parts.first;
          final mode = parts.length == 1 ? 'rw' : parts.last;
          final revoked = location.startsWith('!');
          final target = revoked ? location.substring(1) : location;
          final exact = target == 'xdg-config/autostart';
          final broad = sameConfig && (target == 'xdg-config' || target == 'host' || (target == 'home' && absolute(home) && p.posix.isWithin(home!, config)));
          final autostart = p.posix.join(config, 'autostart');
          final explicit = sameConfig && absolute(target) && (p.posix.normalize(target) == autostart || p.posix.isWithin(target, autostart));
          if (!exact && !broad && !explicit) continue;
          if (revoked || mode == 'none') {
            denied = true;
          } else if (mode == 'ro' || mode == 'rw' || mode == 'create') {
            modes.add(mode == 'ro' ? 'ro' : 'rw');
            readable = true;
            writable = writable || mode != 'ro';
          } else {
            denied = true;
          }
        }
        if (denied || modes.length > 1) readable = writable = false;
      }
    }
    return LinuxAutoStart._(
      config == null ? null : p.posix.join(config, 'autostart', '$packageName.desktop'),
      appName,
      flatpakInfo == null ? [executable] : _flatpakCommand,
      flatpakInfo == null ? executable : '/app/localsend_app',
      flatpakInfo != null,
      readable,
      writable,
    );
  }

  AutoStartSnapshot snapshot() {
    if (!readable || filePath == null) return _unavailable;
    try {
      final file = File(filePath!);
      final directory = file.parent;
      bool canModify = writable;
      if (directory.existsSync()) {
        // Listing fails for inaccessible mapped directories; search permission is also needed.
        directory.listSync(followLinks: false);
        final mode = directory.statSync().mode;
        if ((mode & 0x49) == 0) return _unavailable;
        // No write bits is a definite denial. ACLs and mounts may still deny a
        // write-capable grant; the mutation's IO result remains authoritative.
        canModify = canModify && (mode & 0x92) != 0;
      } else if (flatpak) {
        return _unavailable;
      }
      final type = FileSystemEntity.typeSync(file.path);
      if (type == FileSystemEntityType.notFound) {
        return AutoStartSnapshot(enabled: false, hidden: false, canModify: canModify);
      }
      if (type != FileSystemEntityType.file) return _unavailable;
      final contents = file.readAsStringSync();
      final entry = parseLinuxAutoStartEntry(contents, command) ?? _parseLegacyEntry(contents);
      if (entry == null) return _unavailable;
      return AutoStartSnapshot(enabled: entry.enabled, hidden: entry.hidden, canModify: canModify);
    } on FileSystemException {
      return _unavailable;
    }
  }

  AutoStartSnapshot? _parseLegacyEntry(String contents) {
    final entry = _parseGroups(contents)?['Desktop Entry'];
    if (entry == null || entry['Type'] != 'Application' || entry['Name'] != appName ||
        entry['Comment'] != '$appName startup script' || entry['StartupNotify'] != 'false' || entry['Terminal'] != 'false') {
      return null;
    }
    for (final key in ['Hidden', 'X-GNOME-Autostart-enabled']) {
      if (entry[key] != null && entry[key] != 'true' && entry[key] != 'false') return null;
    }
    final exec = entry['Exec'];
    if (exec != legacyExecutable && exec != '$legacyExecutable --hidden') return null;
    // The old writer's literal sandbox path or unquoted native path is not a
    // valid selected registration. Keep it repairable by an explicit enable.
    return AutoStartSnapshot(enabled: false, hidden: exec == '$legacyExecutable --hidden', canModify: true);
  }

  bool enable({required bool hidden}) {
    if (!snapshot().canModify || filePath == null) return false;
    File? temporary;
    try {
      final file = File(filePath!);
      file.parent.createSync(recursive: true);
      temporary = File('${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp');
      temporary.writeAsStringSync(serializeLinuxAutoStartEntry(appName, [...command, if (hidden) '--hidden']), flush: true);
      temporary.renameSync(file.path);
      return true;
    } on FileSystemException {
      return false;
    } finally {
      try {
        if (temporary?.existsSync() ?? false) temporary!.deleteSync();
      } on FileSystemException {
        // A failed cleanup must not turn a denied write into an exception.
      }
    }
  }

  bool disable() {
    if (!snapshot().canModify || filePath == null) return false;
    try {
      final file = File(filePath!);
      if (file.existsSync()) file.deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }
}

Map<String, Map<String, String>>? _parseGroups(String contents) {
  final groups = <String, Map<String, String>>{};
  Map<String, String>? group;
  for (final raw in contents.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      final name = line.substring(1, line.length - 1);
      if (groups.containsKey(name)) return null;
      group = groups[name] = {};
    } else {
      final separator = line.indexOf('=');
      if (separator <= 0 || group == null) return null;
      final key = line.substring(0, separator).trim();
      if (group.containsKey(key)) return null;
      group[key] = line.substring(separator + 1);
    }
  }
  return groups;
}

AutoStartSnapshot? parseLinuxAutoStartEntry(String contents, List<String> expectedCommand) {
  final entry = _parseGroups(contents)?['Desktop Entry'];
  if (entry == null || entry['Type'] != 'Application' || entry['Name']?.isNotEmpty != true) return null;
  for (final key in ['Hidden', 'X-GNOME-Autostart-enabled']) {
    final value = entry[key];
    if (value != null && value != 'true' && value != 'false') return null;
  }
  final args = _parseExec(entry['Exec'] ?? '');
  if (args == null || args.length < expectedCommand.length || args.length > expectedCommand.length + 1) return null;
  for (var i = 0; i < expectedCommand.length; i++) {
    if (args[i] != expectedCommand[i]) return null;
  }
  final hidden = args.length == expectedCommand.length + 1;
  if (hidden && args.last != '--hidden') return null;
  return AutoStartSnapshot(
    enabled: entry['Hidden'] != 'true' && entry['X-GNOME-Autostart-enabled'] != 'false',
    hidden: hidden,
    canModify: true,
  );
}

String serializeLinuxAutoStartEntry(String name, List<String> command) {
  String value(String input) => input.replaceAll('\\', r'\\').replaceAll('\n', r'\n').replaceAll('\r', r'\r');
  String token(String input) {
    final escaped = input.replaceAll('%', '%%').replaceAll('\\', r'\\').replaceAll('"', r'\"').replaceAll(r'$', r'\$').replaceAll('`', r'\`');
    return value('"$escaped"');
  }
  return '[Desktop Entry]\nType=Application\nName=${value(name)}\nExec=${command.map(token).join(' ')}\nStartupNotify=false\nTerminal=false\n';
}

List<String>? _parseExec(String value) {
  // Desktop string escaping is processed before Exec quoting.
  final decoded = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    if (value[i] != '\\') {
      decoded.write(value[i]);
      continue;
    }
    if (++i == value.length) return null;
    final escaped = value[i];
    final replacement = {'s': ' ', 'n': '\n', 't': '\t', 'r': '\r', '\\': '\\'}[escaped];
    if (replacement == null) return null;
    decoded.write(replacement);
  }
  final input = decoded.toString();
  final args = <String>[];
  var token = StringBuffer();
  bool quoted = false;
  bool started = false;
  for (var i = 0; i < input.length; i++) {
    final char = input[i];
    if (char == '"') {
      quoted = !quoted;
      started = true;
    } else if (char == '\\') {
      if (++i == input.length || !['"', '\\', r'$', '`'].contains(input[i])) return null;
      token.write(input[i]);
      started = true;
    } else if (char == '%') {
      if (++i == input.length || input[i] != '%') return null;
      token.write('%');
      started = true;
    } else if (!quoted && (char == ' ' || char == '\t')) {
      if (started) {
        args.add(token.toString());
        token = StringBuffer();
        started = false;
      }
    } else {
      if (char == '\n' || char == '\r' || (!quoted && "'<>~|&;\$*?#()`".contains(char))) return null;
      token.write(char);
      started = true;
    }
  }
  if (quoted) return null;
  if (started) args.add(token.toString());
  return args.isEmpty ? null : args;
}
