import Foundation

let command = CommandLine.arguments[1]
let path = CommandLine.arguments[2]
do {
  if command == "recover" {
    try DaemonIPC.removeStaleSocket(path)
  } else if command == "shutdown" || command == "shutdown-live" {
    try DaemonIPC(socketPath: path, token: "test-token").shutdown()
    if command == "shutdown-live" { try FileHandle.standardOutput.write(contentsOf: Data("ack\n".utf8)) }
  } else if command == "watch" || command == "watch-live" {
    var pendingDecisions = 0
    try DaemonIPC(socketPath: path, token: "test-token").watch { snapshot in
      if let receive = snapshot["receive"] as? [String: Any], receive["status"] as? String == "pending" {
        pendingDecisions += 1
        if command == "watch-live" { try! FileHandle.standardOutput.write(contentsOf: Data("pending\n".utf8)) }
      }
    }
    guard pendingDecisions == 1 else { throw LauncherError.message("Pending decision was not delivered") }
  } else {
    throw LauncherError.message("Unknown test command")
  }
} catch {
  fputs("\(error)\n", stderr)
  exit(1)
}
