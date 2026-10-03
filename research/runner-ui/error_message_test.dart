import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/util/rust.dart';

void main() {
  const patched = bool.fromEnvironment('RESEARCH_PATCHED');
  final cases = <String, RsHttpClientError>{
    'reqwest': const RsHttpClientError.reqwest('Connection refused'),
    'json': const RsHttpClientError.json('Invalid JSON'),
    'io': const RsHttpClientError.io('Disk full'),
    'other': const RsHttpClientError.other('Upload cancelled'),
  };
  final results = <Map<String, Object?>>[];
  tearDownAll(() => File('error-results-${patched ? 'after' : 'before'}.json').writeAsStringSync(jsonEncode(results)));
  for (final item in cases.entries) {
    test('existing ${item.key} error payload', () {
      final actual = item.value.humanErrorMessage;
      final payload = switch (item.value) {
        RsHttpClientError_Reqwest(:final field0) => field0,
        RsHttpClientError_Json(:final field0) => field0,
        RsHttpClientError_Io(:final field0) => field0,
        RsHttpClientError_Other(:final field0) => field0,
        _ => throw StateError('Invalid fixture'),
      };
      if (patched) {
        expect(actual, payload);
      } else {
        expect(actual, contains('RsHttpClientError.${item.key}(field0:'));
        expect(actual, isNot(payload));
      }
      results.add({'case': item.key, 'patched': patched, 'actual': actual, 'payload': payload});
      print('ERROR_RESULT ${jsonEncode(results.last)}');
    });
  }
  test('HTTP status and ordinary fallback controls', () {
    expect(const RsHttpClientError.statusCode(status: 403, message: 'Denied').humanErrorMessage, '[403] Denied');
    expect('plain message'.humanErrorMessage, 'plain message');
    results.add({'case': 'controls', 'patched': patched, 'passed': true});
  });
}
