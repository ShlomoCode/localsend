import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/model/send_mode.dart';
import 'package:localsend_app/model/state/settings_state.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/rust/api/model.dart' as rust;
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:refena_flutter/refena_flutter.dart';

// Install into app/test/protocol_size_test.dart at the exact audit pin.
// It calls the real SendNotifier.startSession and intercepts only the network
// boundary. No native library, peer, sockets, or network experiments are used.
void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('localsend-stale-size-');
    api.client.requests.clear();
  });
  tearDown(() => directory.deleteSync(recursive: true));

  Future<rust.FileDto> advertised(CrossFile selection) async {
    final container = RefenaContainer(
      overrides: [
        httpProvider.overrideWithBuilder((_) => HttpClientCollection(privateKey: '', certificate: '', discovery: api.client)),
        settingsProvider.overrideWithNotifier((_) => _Settings()),
        deviceFullInfoProvider.overrideWithBuilder((_) => Device.empty.copyWith(alias: 'sender', version: '2.2', ip: '127.0.0.1', port: 53317)),
      ],
    );
    try {
      await container
          .notifier(sendProvider)
          .startSession(
            target: Device.empty.copyWith(ip: '127.0.0.2', port: 53317, fingerprint: 'peer'),
            files: [selection],
            background: true,
          );
      expect(api.client.requests, hasLength(1));
      return api.client.requests.single.files.values.single;
    } finally {
      container.disposeContainer();
      api.client.requests.clear();
    }
  }

  test('retained ordinary path advertises new byte length after grow and shrink', () async {
    for (final changedLength in [14, 4]) {
      final source = File('${directory.path}/source-$changedLength.bin')..writeAsBytesSync(List.filled(11, 65));
      final selection = _file(path: source.path, size: source.lengthSync());
      source.writeAsBytesSync(List.filled(changedLength, 66));
      final request = await advertised(selection);
      expect(request.size, BigInt.from(changedLength));
      expect(selection.size, 11, reason: 'The same retained immutable selection is used; no reselection workaround.');
    }
  });

  test('unchanged ordinary source retains advertised length and filename', () async {
    final source = File('${directory.path}/unchanged.bin')..writeAsBytesSync(List.filled(11, 65));
    final request = await advertised(_file(path: source.path, size: 11));
    expect(request.size, BigInt.from(11));
    expect(request.fileName, 'selected.bin');
  });

  test('in-memory file does not stat a conflicting disk path', () async {
    final source = File('${directory.path}/bytes.bin')..writeAsBytesSync(List.filled(14, 65));
    final request = await advertised(_file(path: source.path, size: 3, bytes: Uint8List.fromList([1, 2, 3])));
    expect(request.size, BigInt.from(3));
  });

  test('SAF URI retains provider metadata without native stat', () async {
    final request = await advertised(_file(path: 'content://provider/document/opaque', size: 11));
    expect(request.size, BigInt.from(11));
  });

  test('missing ordinary source preserves original prepare metadata and error flow', () async {
    final request = await advertised(_file(path: '${directory.path}/missing.bin', size: 11));
    expect(request.size, BigInt.from(11));
  });
}

CrossFile _file({required String path, required int size, List<int>? bytes}) => CrossFile(
  name: 'selected.bin',
  fileType: FileType.other,
  size: size,
  thumbnail: null,
  asset: null,
  path: path,
  bytes: bytes,
  lastModified: null,
  lastAccessed: null,
);

class _Api implements RustLibApi {
  final client = _Client();
  @override
  RsCancellationToken crateApiCancelCreateCancellationToken() => _Token();
  @override
  RsHttpClient crateApiHttpCreateClient({
    required String privateKey,
    required String cert,
    required LsHttpClientVersion version,
    String? expectedFingerprint,
    int? timeoutMs,
  }) => client;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Unmocked Rust API: ${invocation.memberName}');
}

class _Token implements RsCancellationToken {
  @override
  void cancel() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Unmocked token: ${invocation.memberName}');
}

class _Client implements RsHttpClient {
  final requests = <rust.PrepareUploadRequestDto>[];
  @override
  Future<PrepareUploadResult> prepareUpload({
    required rust.ProtocolType protocol,
    required String ip,
    required int port,
    required rust.PrepareUploadRequestDto payload,
    String? publicKey,
    String? pin,
    required RsCancellationToken cancelToken,
  }) async {
    requests.add(payload);
    // Stop at the exact request boundary so no upload/native isolate is needed.
    throw const RsHttpClientError.statusCode(status: 403);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Unmocked client: ${invocation.memberName}');
}

class _UnusedPersistence implements PersistenceService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Unexpected persistence: ${invocation.memberName}');
}

class _Settings extends SettingsService {
  _Settings() : super(_UnusedPersistence());
  @override
  SettingsState init() => const SettingsState(
    showToken: '',
    alias: 'sender',
    theme: ThemeMode.system,
    colorMode: ColorMode.localsend,
    customColor: Colors.blue,
    locale: null,
    port: 53317,
    networkWhitelist: null,
    networkBlacklist: null,
    multicastGroup: '224.0.0.167',
    destination: null,
    saveToGallery: false,
    saveToHistory: false,
    quickSave: false,
    quickSaveFromFavorites: false,
    receivePin: null,
    autoFinish: false,
    minimizeToTray: false,
    https: false,
    sendMode: SendMode.single,
    saveWindowPlacement: false,
    alwaysOnTop: false,
    enableAnimations: false,
    deviceType: null,
    deviceModel: null,
    shareViaLinkAutoAccept: false,
    receiveViaLinkAutoAccept: false,
    createChecksums: false,
    verifyChecksums: false,
    discoveryTimeout: 100,
    advancedSettings: false,
  );
}
