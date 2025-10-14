/// Returns bytes per second
int getFileSpeed({
  required int start,
  required int end,
  required int bytes,
}) {
  final deltaTime = end - start;
  return (1000 * bytes) ~/ deltaTime; // multiply by 1000 to convert millis to seconds
}

String getRemainingTime({
  required int bytesPerSeconds,
  required int remainingBytes,
}) {
  final totalSeconds = _getRemainingTime(bytesPerSeconds: bytesPerSeconds, remainingBytes: remainingBytes);
  
  if (totalSeconds < 60) {
    final seconds = totalSeconds;
    return '0:${seconds.toString().padLeft(2, '0')}';
  } else if (totalSeconds < 3600) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  } else if (totalSeconds < 86400) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    return '${hours}h ${minutes}m';
  } else {
    final days = totalSeconds ~/ 86400;
    final remainingAfterDays = totalSeconds % 86400;
    final hours = remainingAfterDays ~/ 3600;
    final minutes = (remainingAfterDays % 3600) ~/ 60;
    return '${days}d ${hours}h ${minutes}m';
  }
}

/// Returns remaining time in seconds
int _getRemainingTime({
  required int bytesPerSeconds,
  required int remainingBytes,
}) {
  return remainingBytes ~/ bytesPerSeconds;
}
