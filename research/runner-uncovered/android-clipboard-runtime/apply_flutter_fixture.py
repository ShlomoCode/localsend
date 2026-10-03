#!/usr/bin/env python3
"""Install source-exact before/after fixture into an existing /tmp scratch checkout."""
import argparse
from pathlib import Path
import shutil

parser = argparse.ArgumentParser()
parser.add_argument('--repo', type=Path, required=True)
parser.add_argument('--mode', choices=['baseline', 'patched'], required=True)
args = parser.parse_args()
repo = args.repo.resolve()
if not any(root == repo or root in repo.parents for root in (Path('/tmp').resolve(), Path('/private/tmp').resolve())):
    parser.error('Fixture only writes a scratch checkout under /tmp or /private/tmp.')
source = Path(__file__).resolve().parent
for relative in ('app/lib/util/native/file_picker.dart', 'app/lib/util/native/channel/android_channel.dart'):
    content = (source / (args.mode + '-' + relative.replace('/', '__'))).read_text()
    if relative.endswith('file_picker.dart'):
        seam = 'final _uriContent = UriContent();'
        if content.count(seam) != 1:
            raise ValueError('Unexpected UriContent declaration')
        # Dependency chooses dart:io Platform. This sole test seam makes URI metadata
        # mockable on Linux; both baseline and patched get the identical substitution.
        content = content.replace(seam, 'final _uriContent = UriContent(internalPlatform: TargetPlatform.android);')
    target = repo / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)
target = repo / 'app/test/fresh_clipboard_2862_test.dart'
target.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(source / 'fresh_clipboard_2862_test.dart', target)
print(f'Applied {args.mode} fixture at {repo}; identical Linux UriContent seam in each mode.')
