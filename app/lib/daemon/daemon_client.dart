import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class DaemonConnectionOptions {
  final String socketPath;
  final String tokenFile;

  const DaemonConnectionOptions({
    required this.socketPath,
    required this.tokenFile,
  });

  static DaemonConnectionOptions fromArguments(List<String> args) {
    String requiredArgument(String name) {
      final index = args.indexOf(name);
      if (index < 0 || index + 1 >= args.length || args[index + 1].startsWith('--')) {
        throw FormatException('Missing $name');
      }
      return args[index + 1];
    }

    return DaemonConnectionOptions(
      socketPath: requiredArgument('--daemon-socket'),
      tokenFile: requiredArgument('--daemon-token-file'),
    );
  }
}

class DaemonCommandException implements Exception {
  final String code;
  final String message;
  const DaemonCommandException(this.code, this.message);
  @override
  String toString() => message;
}

class DaemonReceiveFile {
  final String id;
  final String name;
  final int size;
  final int receivedBytes;
  final String status;
  final String? path;
  final String? error;

  DaemonReceiveFile.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      name = json['name'] as String,
      size = json['size'] as int,
      receivedBytes = json['received_bytes'] as int,
      status = json['status'] as String,
      path = json['path'] as String?,
      error = json['error'] as String?;
}

class DaemonReceive {
  final String sessionId;
  final String senderAlias;
  final String senderFingerprint;
  final String status;
  final List<DaemonReceiveFile> files;

  DaemonReceive.fromJson(Map<String, dynamic> json)
    : sessionId = json['session_id'] as String,
      senderAlias = json['sender_alias'] as String,
      senderFingerprint = json['sender_fingerprint'] as String,
      status = json['status'] as String,
      files = (json['files'] as List)
          .map(
            (file) => DaemonReceiveFile.fromJson(file as Map<String, dynamic>),
          )
          .toList(growable: false);
}

class DaemonSnapshot {
  final int revision;
  final int port;
  final DaemonReceive? receive;
  final String? error;

  DaemonSnapshot.fromJson(Map<String, dynamic> json)
    : revision = json['revision'] as int,
      port = json['port'] as int,
      receive = json['receive'] == null ? null : DaemonReceive.fromJson(json['receive'] as Map<String, dynamic>),
      error = json['error'] as String?;
}

/// Owns only local IPC. Closing this client never cancels a daemon transfer.
class DaemonClient extends ChangeNotifier {
  final DaemonConnectionOptions options;
  final Duration reconnectDelay;
  final Duration commandTimeout;
  DaemonSnapshot? snapshot;
  bool connected = false;
  String? connectionError;
  String? _token;
  int _nextId = 0;
  bool _disposed = false;
  bool _started = false;
  final Set<Socket> _sockets = {};
  Timer? _reconnectTimer;
  Completer<void>? _reconnectWait;

  DaemonClient(
    this.options, {
    this.reconnectDelay = const Duration(seconds: 1),
    this.commandTimeout = const Duration(seconds: 5),
  });

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    try {
      _token = (await File(options.tokenFile).readAsString()).trim();
      if (_token!.isEmpty) throw const FormatException('Daemon token is empty');
    } catch (error) {
      if (!_disposed) {
        connectionError = 'LocalSend connection is unavailable';
        notifyListeners();
      }
      return;
    }
    while (!_disposed) {
      Socket? socket;
      try {
        socket = await _connect();
        if (_disposed) {
          socket.destroy();
          return;
        }
        final id = _request(socket, 'watch');
        await for (final line in socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter())) {
          final response = _decode(line, id);
          if (_disposed) return;
          _applySnapshot(response);
          connected = true;
          connectionError = null;
          notifyListeners();
        }
        if (!_disposed) throw const SocketException('Daemon disconnected');
      } catch (error) {
        if (!_disposed) {
          connected = false;
          connectionError = 'LocalSend connection is unavailable';
          notifyListeners();
        }
      } finally {
        socket?.destroy();
        _sockets.remove(socket);
      }
      if (!_disposed) {
        final wait = Completer<void>();
        _reconnectWait = wait;
        _reconnectTimer = Timer(reconnectDelay, wait.complete);
        await wait.future;
        _reconnectWait = null;
      }
    }
  }

  Future<void> command(
    String command, {
    String? sessionId,
    List<String>? fileIds,
  }) async {
    if (_disposed || _token == null || !connected) {
      throw const DaemonCommandException('disconnected', 'LocalSend connection is unavailable');
    }
    final socket = await _connect();
    try {
      final id = _request(
        socket,
        command,
        sessionId: sessionId,
        fileIds: fileIds,
      );
      final line = await socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).first.timeout(commandTimeout);
      final response = _decode(line, id);
      if (!_disposed) {
        _applySnapshot(response);
        notifyListeners();
      }
    } finally {
      socket.destroy();
      _sockets.remove(socket);
    }
  }

  Future<Socket> _connect() async {
    // A restarted daemon can replace its authentication token at the same path.
    _token = (await File(options.tokenFile).readAsString()).trim();
    if (_token!.isEmpty) throw const FormatException('Daemon token is empty');
    final socket = await Socket.connect(
      InternetAddress(options.socketPath, type: InternetAddressType.unix),
      0,
      timeout: commandTimeout,
    );
    if (_disposed) {
      socket.destroy();
      throw const DaemonCommandException('closed', 'LocalSend window is closed');
    }
    _sockets.add(socket);
    return socket;
  }

  String _request(
    Socket socket,
    String command, {
    String? sessionId,
    List<String>? fileIds,
  }) {
    final id = (++_nextId).toString();
    socket.write(
      '${jsonEncode({'version': 1, 'id': id, 'token': _token, 'command': command, 'session_id': ?sessionId, 'file_ids': ?fileIds})}\n',
    );
    return id;
  }

  Map<String, dynamic> _decode(String line, String id) {
    final response = jsonDecode(line) as Map<String, dynamic>;
    if (response['version'] != 1 || response['id'] != id) throw const FormatException('Invalid daemon response');
    if (response['ok'] != true) {
      final error = response['error'] as Map<String, dynamic>;
      throw DaemonCommandException(
        error['code'] as String,
        error['message'] as String,
      );
    }
    return response;
  }

  void _applySnapshot(Map<String, dynamic> response) {
    final next = DaemonSnapshot.fromJson(
      response['snapshot'] as Map<String, dynamic>,
    );
    if (snapshot == null || !connected || next.revision >= snapshot!.revision) snapshot = next;
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    if (_reconnectWait case final wait? when !wait.isCompleted) wait.complete();
    for (final socket in _sockets.toList(growable: false)) {
      socket.destroy();
    }
    _sockets.clear();
    super.dispose();
  }
}
