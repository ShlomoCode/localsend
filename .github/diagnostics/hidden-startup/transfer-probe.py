#!/usr/bin/env python3
"""Disposable localhost mTLS protocol-v2 transfer probe; no production trust changes."""
import argparse
import hashlib
import http.client
import json
import re
import socket
import ssl
import sys
import time
from pathlib import Path
from urllib.parse import urlencode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cert', required=True)
    parser.add_argument('--key', required=True)
    parser.add_argument('--destination', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--label', default='probe')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.label):
        parser.error('--label must contain only letters, digits, underscores, or hyphens')
    args.evidence.mkdir(parents=True, exist_ok=True)
    events = []
    started = time.monotonic()
    stage = 'setup'

    def log(status, **fields):
        event = dict(label=args.label, stage=stage, status=status,
                     elapsed_seconds=round(time.monotonic() - started, 3), **fields)
        events.append(event)
        print(json.dumps(event), flush=True)
        (args.evidence / (args.label + '-transfer.json')).write_text(
            json.dumps(events, indent=2) + '\n')

    def request(method, path, body=None, content_type=None):
        # The endpoint is fixed to loopback and belongs to an ephemeral test
        # container. LocalSend intentionally uses self-signed per-device TLS.
        conn = http.client.HTTPSConnection('127.0.0.1', 53317, context=context, timeout=10)
        try:
            conn.connect()
            log('tls_connected')
            headers = {'Content-Type': content_type} if content_type else {}
            conn.request(method, '/api/localsend/v2/' + path, body=body, headers=headers)
            log('request_sent')
            response = conn.getresponse()
            data = response.read()
            log('http_response', http_status=response.status, response_bytes=len(data))
            if response.status != 200:
                raise RuntimeError('Unexpected HTTP status ' + str(response.status))
            return data
        finally:
            conn.close()

    try:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        context.load_cert_chain(args.cert, args.key)
        pem = Path(args.cert).read_text()
        match = re.search(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', pem, re.S)
        if match is None:
            raise ValueError('Client certificate file contains no PEM certificate')
        fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(match.group())).hexdigest().upper()
        payload = b'LocalSend startup receive probe\x00\xff\n' + bytes(range(256)) * 17
        digest = hashlib.sha256(payload).hexdigest()
        (args.evidence / (args.label + '-fixture.bin')).write_bytes(payload)
        target = args.destination / 'startup-probe.bin'
        if target.exists():
            raise RuntimeError('Destination fixture already exists; use a clean test destination')
        stage = 'info'
        info = json.loads(request('GET', 'info'))
        log('info_verified', protocol_version=info.get('version'))
        stage = 'prepare_upload'
        body = {'info': {'alias': 'Startup Probe', 'version': '2.2',
                        'deviceType': 'desktop', 'fingerprint': fingerprint,
                        'port': 53318, 'protocol': 'https', 'download': False},
                'files': {'startup-probe': {'id': 'startup-probe', 'fileName': target.name,
                                          'size': len(payload), 'fileType': 'application/octet-stream',
                                          'sha256': digest}}}
        prepared = json.loads(request('POST', 'prepare-upload', json.dumps(body).encode(), 'application/json'))
        token = prepared['files']['startup-probe']
        session = prepared['sessionId']
        log('accepted', accepted_files=len(prepared['files']))
        stage = 'upload'
        query = urlencode({'sessionId': session, 'fileId': 'startup-probe', 'token': token})
        request('POST', 'upload?' + query, payload, 'application/octet-stream')
        stage = 'verify_saved_file'
        deadline = time.monotonic() + 5
        while not target.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        actual = target.read_bytes()
        actual_digest = hashlib.sha256(actual).hexdigest()
        if actual != payload:
            log('content_mismatch', expected_sha256=digest, actual_sha256=actual_digest,
                expected_bytes=len(payload), actual_bytes=len(actual))
            return 1
        log('passed', saved_file=str(target), sha256=actual_digest, bytes=len(actual))
        return 0
    except Exception as error:
        if isinstance(error, ConnectionRefusedError):
            status = 'connection_refused'
        elif isinstance(error, ssl.SSLError):
            status = 'tls_error'
        elif isinstance(error, (TimeoutError, socket.timeout)):
            status = 'request_timeout'
        elif isinstance(error, FileNotFoundError) and stage == 'verify_saved_file':
            status = 'saved_file_missing'
        else:
            status = 'failed'
        log(status, error_type=type(error).__name__, error=str(error))
        return 1


if __name__ == '__main__':
    sys.exit(main())
