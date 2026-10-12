import * as receiver from './receiver.mjs';
import {runAndroidSender} from '../3441-android/controller.mjs';
if(process.env.GITHUB_ACTIONS!=='true'||process.env.GITHUB_REPOSITORY!=='ShlomoCode/localsend'||process.env.ISSUE3441_ADMITTED!=='1')throw Error('Transfer requires an admitted fork Actions job before receiver preparation or relay startup');
await receiver.ready();
try {
  await receiver.startRelay();
  await runAndroidSender({output:'evidence/issue3441/android',fixtureDirectory:process.env.FIXTURE_DIRECTORY,receiver});
} finally {
  await receiver.stopRelay();
}
