import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/daemon/daemon_client.dart';

Future<void> runDaemonApp(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final client = DaemonClient(DaemonConnectionOptions.fromArguments(args));
    runApp(DaemonApp(client: client));
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(child: const Text('Cannot open LocalSend')),
        ),
      ),
    );
  }
}

class DaemonApp extends StatefulWidget {
  final DaemonClient client;
  const DaemonApp({required this.client});

  @override
  State<DaemonApp> createState() => _DaemonAppState();
}

class _DaemonAppState extends State<DaemonApp> {
  bool _busy = false;
  String? _commandError;

  @override
  void initState() {
    super.initState();
    unawaited(widget.client.start());
  }

  @override
  void dispose() {
    widget.client.dispose();
    super.dispose();
  }

  Future<void> _command(String command, String sessionId) async {
    setState(() {
      _busy = true;
      _commandError = null;
    });
    try {
      await widget.client.command(command, sessionId: sessionId);
    } catch (error) {
      if (mounted) {
        setState(() {
          _commandError = error.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LocalSend',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(title: const Text('LocalSend')),
        body: AnimatedBuilder(
          animation: widget.client,
          builder: (context, _) {
            final client = widget.client;
            final receive = client.snapshot?.receive;
            final enabled = client.connected && !_busy;
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!client.connected) Text('Waiting for LocalSend…'),
                  if (client.snapshot?.error != null) Text(client.snapshot!.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 16),
                  if (receive == null)
                    Expanded(
                      child: Center(
                        child: Text(
                          !client.connected
                              ? 'Waiting for LocalSend…'
                              : client.snapshot?.error == null
                              ? 'Ready to receive'
                              : 'LocalSend needs attention',
                        ),
                      ),
                    ),
                  if (receive != null) ...[
                    Text(
                      'From ${receive.senderAlias}',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    SelectableText(
                      receive.senderFingerprint,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(_statusLabel(receive)),
                    const SizedBox(height: 16),
                    Expanded(
                      child: ListView.builder(
                        itemCount: receive.files.length,
                        itemBuilder: (context, index) {
                          final file = receive.files[index];
                          return ListTile(
                            title: Text(file.name),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${file.receivedBytes} / ${file.size} bytes · ${file.status}',
                                ),
                                if (file.status == 'receiving')
                                  LinearProgressIndicator(
                                    value: file.size == 0 ? null : (file.receivedBytes / file.size).clamp(0, 1),
                                  ),
                                if (file.path != null) SelectableText(file.path!),
                                if (file.error != null) Text(file.error!),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    if (receive.status == 'pending')
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          OutlinedButton(
                            onPressed: enabled
                                ? () => unawaited(
                                    _command('decline', receive.sessionId),
                                  )
                                : null,
                            child: const Text('Decline'),
                          ),
                          const SizedBox(width: 12),
                          FilledButton(
                            onPressed: enabled
                                ? () => unawaited(
                                    _command('accept', receive.sessionId),
                                  )
                                : null,
                            child: const Text('Accept'),
                          ),
                        ],
                      ),
                    if (receive.status == 'receiving')
                      OutlinedButton(
                        onPressed: enabled
                            ? () => unawaited(
                                _command('cancel', receive.sessionId),
                              )
                            : null,
                        child: const Text('Cancel transfer'),
                      ),
                  ],
                  if (_commandError != null)
                    Text(
                      _commandError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  String _statusLabel(DaemonReceive receive) => switch (receive.status) {
    'pending' => 'Incoming files — accept or decline',
    'receiving' => 'Receiving files…',
    'finished' => receive.files.every((file) => file.status == 'finished') ? 'Transfer complete' : 'Transfer finished with incomplete files',
    'cancelled' => 'Transfer cancelled',
    'aborted' => 'Sender disconnected before the transfer completed',
    _ => receive.status,
  };
}
