import 'package:localsend_isolates/model/file_status.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// A provider holding the live per-file transfer state (status and progress).
/// It is implemented as [ChangeNotifier] for performance reasons:
/// a status or progress update does not need to copy the whole session state.
final fileTransferProvider = ChangeNotifierProvider((ref) => FileTransferNotifier());

class FileTransfer {
  FileStatus status;
  double progress; // 0..1

  FileTransfer(this.status) : progress = 0;

  @override
  String toString() => '($status, $progress)';
}

class FileTransferNotifier extends ChangeNotifier {
  final _sessionMap = <String, Map<String, FileTransfer>>{}; // session id -> (file id -> live transfer state)
  final _totals = <String, _TransferTotals>{};

  /// Registers file sizes once so progress updates can update the displayed total in constant time.
  void trackTotals(String sessionId, Map<String, int> fileSizes) {
    final files = _sessionMap[sessionId];
    _totals[sessionId] = _TransferTotals(
      fileSizes: fileSizes,
      bytes: files?.entries.fold<int>(0, (sum, entry) => sum + ((entry.value.progress * (fileSizes[entry.key] ?? 0)).round())) ?? 0,
      finishedCount: files?.values.where((file) => file.status == FileStatus.finished).length ?? 0,
    );
  }

  ({int bytes, int finishedCount}) getTotals(String sessionId) {
    final totals = _totals[sessionId];
    return (bytes: totals?.bytes ?? 0, finishedCount: totals?.finishedCount ?? 0);
  }

  void setStatus({required String sessionId, required String fileId, required FileStatus status}) {
    final file = _sessionMap.putIfAbsent(sessionId, () => {}).putIfAbsent(fileId, () => FileTransfer(FileStatus.queue));
    final totals = _totals[sessionId];
    if (totals != null) {
      totals.finishedCount += (status == FileStatus.finished ? 1 : 0) - (file.status == FileStatus.finished ? 1 : 0);
    }
    file.status = status;
    notifyListeners();
  }

  /// Sets the status of multiple files at once, notifying listeners only once.
  void setStatuses({required String sessionId, required Map<String, FileStatus> statuses}) {
    final files = _sessionMap.putIfAbsent(sessionId, () => {});
    final totals = _totals[sessionId];
    for (final entry in statuses.entries) {
      final file = files.putIfAbsent(entry.key, () => FileTransfer(FileStatus.queue));
      if (totals != null) {
        totals.finishedCount += (entry.value == FileStatus.finished ? 1 : 0) - (file.status == FileStatus.finished ? 1 : 0);
      }
      file.status = entry.value;
    }
    notifyListeners();
  }

  void setProgress({required String sessionId, required String fileId, required double progress}) {
    final file = _sessionMap.putIfAbsent(sessionId, () => {}).putIfAbsent(fileId, () => FileTransfer(FileStatus.queue));
    final totals = _totals[sessionId];
    if (totals != null) {
      final size = totals.fileSizes[fileId] ?? 0;
      totals.bytes += (progress * size).round() - (file.progress * size).round();
    }
    file.progress = progress;
    notifyListeners();
  }

  FileStatus getStatus({required String sessionId, required String fileId}) {
    return _sessionMap[sessionId]?[fileId]?.status ?? FileStatus.queue;
  }

  Iterable<FileStatus> getStatuses(String sessionId) {
    return _sessionMap[sessionId]?.values.map((file) => file.status) ?? const [];
  }

  double getProgress({required String sessionId, required String fileId}) {
    return _sessionMap[sessionId]?[fileId]?.progress ?? 0.0;
  }

  void removeSession(String sessionId) {
    _sessionMap.remove(sessionId);
    _totals.remove(sessionId);
    notifyListeners();
  }

  void removeAllSessions() {
    _sessionMap.clear();
    _totals.clear();
    notifyListeners();
  }

  /// Only for debug purposes
  Map<String, Map<String, FileTransfer>> getData() {
    return _sessionMap;
  }
}

class _TransferTotals {
  final Map<String, int> fileSizes;
  int bytes;
  int finishedCount;

  _TransferTotals({required this.fileSizes, required this.bytes, required this.finishedCount});
}
