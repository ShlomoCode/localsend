#!/usr/bin/env python3
import argparse
from pathlib import Path
import shutil
parser=argparse.ArgumentParser()
parser.add_argument('--repo',type=Path,required=True)
parser.add_argument('--mode',choices=['before','after'],required=True)
args=parser.parse_args()
repo=args.repo.resolve()
if not any(root==repo or root in repo.parents for root in (Path('/tmp').resolve(),Path('/private/tmp').resolve())):
    parser.error('Only a disposable scratch checkout under /tmp may be changed.')
source=Path(__file__).resolve().parent
for relative in ('app/android/app/src/main/kotlin/org/localsend/localsend_app/MainActivity.kt','app/lib/util/native/channel/android_channel.dart','app/lib/util/native/file_picker.dart'):
    content=(source/('fresh-nullclip-inapp-'+args.mode+'-'+relative.replace('/','__'))).read_text()
    if relative.endswith('file_picker.dart'):
        target='final _uriContent = UriContent();'
        assert content.count(target)==1
        content=content.replace(target,'final _uriContent = UriContent(internalPlatform: TargetPlatform.android);')
    target=repo/relative
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_text(content)
target=repo/'app/test/fresh_nullclip_inapp_test.dart'
target.parent.mkdir(parents=True,exist_ok=True)
shutil.copyfile(source/'fresh-nullclip-inapp-fixture_test.dart',target)
print('Applied '+args.mode+' source and identical Linux UriContent metadata-only test seam.')
