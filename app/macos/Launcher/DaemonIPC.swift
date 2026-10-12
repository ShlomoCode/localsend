import Foundation
import Darwin

enum LauncherError: Error, CustomStringConvertible {
  case message(String)
  var description: String { if case let .message(text) = self { return text }; return "Launcher error" }
}

private struct SocketConnectError: Error { let code: Int32 }

// Each command owns a connection; watch uses a separate, long-lived connection.
final class DaemonIPC {
  let socketPath: String
  let token: String
  init(socketPath: String, token: String) { self.socketPath = socketPath; self.token = token }

  private static func openSocket(_ socketPath: String) throws -> FileHandle {
    let bytes = Array(socketPath.utf8) + [0]
    var address = sockaddr_un()
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw LauncherError.message("Daemon socket path exceeds the macOS Unix socket limit")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes) }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw LauncherError.message("socket: \(String(cString: strerror(errno)))") }
    var noSigPipe: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let code = errno; Darwin.close(descriptor)
      throw SocketConnectError(code: code)
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  // Only call after obtaining the launcher lock in an owner-only directory.
  static func removeStaleSocket(_ path: String) throws {
    var before = stat()
    if lstat(path, &before) != 0 {
      if errno == ENOENT { return }
      throw LauncherError.message("Unable to inspect daemon socket")
    }
    guard (before.st_mode & S_IFMT) == S_IFSOCK, before.st_uid == getuid() else {
      throw LauncherError.message("Refusing to remove a non-socket or another user's socket")
    }
    do {
      let active = try openSocket(path); try active.close()
      throw LauncherError.message("A receiver is already listening on this socket")
    } catch let error as SocketConnectError {
      guard error.code == ECONNREFUSED else { throw error }
    }
    var after = stat()
    guard lstat(path, &after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino,
          (after.st_mode & S_IFMT) == S_IFSOCK, after.st_uid == getuid(), unlink(path) == 0 else {
      throw LauncherError.message("Daemon socket changed during stale socket recovery")
    }
  }

  private func connect(command: String) throws -> (FileHandle, String) {
    let handle = try Self.openSocket(socketPath)
    let id = UUID().uuidString
    var request: [String: Any] = ["version": 1, "id": id, "token": token, "command": command]
    if command == "watch" { request["include_progress"] = false }
    var data = try JSONSerialization.data(withJSONObject: request); data.append(10)
    do { try handle.write(contentsOf: data) } catch { try? handle.close(); throw error }
    return (handle, id)
  }

  private func readAvailable(_ handle: FileHandle, capacity: Int) throws -> Data? {
    var bytes = [UInt8](repeating: 0, count: capacity)
    while true {
      let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
      if count > 0 { return Data(bytes.prefix(count)) }
      if count == 0 { return nil }
      if errno == EINTR { continue }
      throw LauncherError.message("Daemon socket read failed: \(String(cString: strerror(errno)))")
    }
  }

  func watch(_ receive: @escaping ([String: Any]) -> Void) throws {
    let (handle, _) = try connect(command: "watch")
    defer { try? handle.close() }
    var pending = Data()
    while let chunk = try readAvailable(handle, capacity: 8192) {
      pending.append(chunk)
      while let newline = pending.firstIndex(of: 10) {
        let line = pending.prefix(upTo: newline); pending.removeSubrange(...newline)
        try autoreleasepool {
          guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                reply["version"] as? Int == 1, reply["ok"] as? Bool == true,
                let snapshot = reply["snapshot"] as? [String: Any] else { return }
          receive(snapshot)
        }
      }
      guard pending.count <= 1024 * 1024 else { throw LauncherError.message("Daemon response too large") }
    }
  }

  func shutdown() throws {
    let (handle, id) = try connect(command: "shutdown")
    defer { try? handle.close() }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    guard setsockopt(handle.fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
      throw LauncherError.message("Unable to set daemon shutdown timeout")
    }
    let deadline = Date().addingTimeInterval(3)
    var pending = Data()
    while Date() < deadline, let chunk = try readAvailable(handle, capacity: 4096) {
      pending.append(chunk)
      if let newline = pending.firstIndex(of: 10) {
        guard let reply = try JSONSerialization.jsonObject(with: pending.prefix(upTo: newline)) as? [String: Any],
              reply["version"] as? Int == 1, reply["id"] as? String == id, reply["ok"] as? Bool == true else {
          throw LauncherError.message("Daemon rejected shutdown")
        }
        return
      }
      guard pending.count <= 65536 else { throw LauncherError.message("Daemon shutdown reply too large") }
    }
    throw LauncherError.message("Daemon did not acknowledge shutdown")
  }
}
