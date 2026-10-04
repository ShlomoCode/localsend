import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:test/test.dart';

void main() {
  test('totals follow late registration, per-file rounding, status changes, and session removal', () {
    final notifier = FileTransferNotifier();

    // A fast transfer can update before the progress page registers the sizes.
    notifier.setProgress(sessionId: 'one', fileId: 'a', progress: 0.25);
    notifier.setStatus(sessionId: 'one', fileId: 'a', status: FileStatus.finished);
    notifier.trackTotals('one', {'a': 3, 'b': 3});
    expect(notifier.getTotals('one'), (bytes: 1, finishedCount: 1));

    notifier.setProgress(sessionId: 'one', fileId: 'b', progress: 0.25);
    expect(notifier.getTotals('one'), (bytes: 2, finishedCount: 1));
    notifier.setProgress(sessionId: 'one', fileId: 'a', progress: 1);
    notifier.setStatuses(sessionId: 'one', statuses: {'a': FileStatus.failed, 'b': FileStatus.finished});
    expect(notifier.getTotals('one'), (bytes: 4, finishedCount: 1));

    notifier.setStatus(sessionId: 'one', fileId: 'b', status: FileStatus.finished);
    notifier.setProgress(sessionId: 'one', fileId: 'b', progress: 1);
    expect(notifier.getTotals('one'), (bytes: 6, finishedCount: 1));
    notifier.setProgress(sessionId: 'one', fileId: 'b', progress: 0.25);
    expect(notifier.getTotals('one'), (bytes: 4, finishedCount: 1));

    notifier.trackTotals('two', {'a': 10});
    notifier.setProgress(sessionId: 'two', fileId: 'a', progress: 0.5);
    notifier.removeSession('one');
    expect(notifier.getTotals('one'), (bytes: 0, finishedCount: 0));
    expect(notifier.getTotals('two'), (bytes: 5, finishedCount: 0));
    notifier.removeAllSessions();
    expect(notifier.getTotals('two'), (bytes: 0, finishedCount: 0));
  });
}
