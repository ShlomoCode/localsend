import AppKit
import Security
import Darwin

func option(_ name: String) -> String? {
  let arguments = CommandLine.arguments
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

func verifyDownloadsAccess() throws {
  let directory = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
  let probe = directory.appendingPathComponent(".localsend-native-access-\(UUID().uuidString)")
  try Data("LocalSend native sandbox access probe".utf8).write(to: probe, options: .withoutOverwriting)
  try FileManager.default.removeItem(at: probe)
  print("Native process Downloads write access verified: \(directory.path)")
}

final class Launcher: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem!
  private var uiProcess: Process?
  private var ipc: DaemonIPC!
  private var lockDescriptor: Int32 = -1
  private var quitting = false
  private var daemonStopped = false
  private var openedSession: String?
  private var uiExecutable: URL!

  func applicationDidFinishLaunching(_ notification: Notification) {
    do { try start() } catch { fail(String(describing: error)) }
  }

  private func start() throws {
    guard let config = option("--config"), let uiPath = option("--ui-app") else {
      throw LauncherError.message("Use --config /absolute/daemon.json --ui-app /absolute/LocalSend.app")
    }
    let uiBundle = URL(fileURLWithPath: uiPath)
    guard let bundle = Bundle(url: uiBundle), let executable = bundle.executableURL else {
      throw LauncherError.message("--ui-app must identify a built Flutter app bundle")
    }
    uiExecutable = executable
    // Development uses private temporary state; production needs shared-container integration.
    let state = option("--state-dir") ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lsd").path
    if !FileManager.default.fileExists(atPath: state) {
      try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    var info = stat()
    guard lstat(state, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
          info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
      throw LauncherError.message("State directory must be an owner-only directory (0700), not a symlink")
    }
    let lock = state + "/launcher.lock"
    lockDescriptor = Darwin.open(lock, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
      throw LauncherError.message("Another launcher already owns this state directory")
    }
    let socket = state + "/ipc.sock"
    try DaemonIPC.removeStaleSocket(socket)
    let tokenFile = state + "/token"
    var random = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
      throw LauncherError.message("Unable to create daemon authentication token")
    }
    let token = random.map { String(format: "%02x", $0) }.joined()
    let tokenFD = Darwin.open(tokenFile, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW, 0o600)
    guard tokenFD >= 0 else { throw LauncherError.message("Unable to write private token file") }
    fchmod(tokenFD, 0o600)
    let tokenHandle = FileHandle(fileDescriptor: tokenFD, closeOnDealloc: true)
    try tokenHandle.write(contentsOf: Data(token.utf8)); try tokenHandle.close()
    ipc = DaemonIPC(socketPath: socket, token: token)
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.image = NSImage(systemSymbolName: "arrow.up.arrow.down.circle", accessibilityDescription: "LocalSend")
    let menu = NSMenu()
    menu.addItem(withTitle: "Open LocalSend", action: #selector(openUI), keyEquivalent: "").target = self
    menu.addItem(NSMenuItem.separator())
    menu.addItem(withTitle: "Quit LocalSend", action: #selector(quit), keyEquivalent: "q").target = self
    statusItem.menu = menu
    DispatchQueue.global(qos: .utility).async {
      let code = config.withCString { configPointer in
        socket.withCString { socketPointer in
          tokenFile.withCString { localsend_daemon_run(configPointer, socketPointer, $0) }
        }
      }
      DispatchQueue.main.async {
        self.daemonStopped = true
        if self.quitting { NSApp.reply(toApplicationShouldTerminate: true) }
        else if code == 0 { NSApp.terminate(nil) }
        else { self.fail("Background receiver stopped (code \(code)).") }
      }
    }
    DispatchQueue.global(qos: .utility).async {
      while true {
        do {
          try self.ipc.watch { snapshot in
            DispatchQueue.main.async { self.receive(snapshot) }
          }
        } catch { /* The daemon may still be starting or temporarily reconnecting. */ }
        if DispatchQueue.main.sync(execute: { self.daemonStopped }) { break }
        Thread.sleep(forTimeInterval: 0.25)
      }
    }
  }

  private func receive(_ snapshot: [String: Any]) {
    guard !quitting, let receive = snapshot["receive"] as? [String: Any],
          receive["status"] as? String == "pending", let session = receive["session_id"] as? String,
          openedSession != session else { return }
    openedSession = session
    openUI()
  }

  @objc private func openUI() {
    guard !quitting else { return }
    if let process = uiProcess, process.isRunning {
      NSRunningApplication(processIdentifier: process.processIdentifier)?.activate(options: [.activateAllWindows])
      return
    }
    let process = Process()
    process.executableURL = uiExecutable
    process.arguments = ["--daemon-mode", "--daemon-socket", ipc.socketPath,
                         "--daemon-token-file", URL(fileURLWithPath: ipc.socketPath).deletingLastPathComponent().appendingPathComponent("token").path]
    process.terminationHandler = { [weak self] terminated in
      DispatchQueue.main.async {
        if self?.uiProcess === terminated { self?.uiProcess = nil }
      }
    }
    do { try process.run(); uiProcess = process } catch {
      let alert = NSAlert(); alert.messageText = "Unable to open LocalSend"; alert.informativeText = String(describing: error)
      alert.runModal()
    }
  }

  @objc private func quit() { NSApp.terminate(nil) }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if daemonStopped || ipc == nil {
      if let process = uiProcess, process.isRunning { process.terminate() }
      return .terminateNow
    }
    if quitting { return .terminateLater }
    quitting = true
    do { try ipc.shutdown() } catch {
      quitting = false
      let alert = NSAlert(); alert.messageText = "Unable to stop background receiver"; alert.informativeText = String(describing: error)
      alert.runModal()
      return .terminateCancel
    }
    // This is only the UI child that this launcher created, never a name-based kill.
    if let process = uiProcess, process.isRunning { process.terminate() }
    return .terminateLater
  }

  private func fail(_ message: String) {
    let alert = NSAlert(); alert.messageText = "LocalSend background receiver"; alert.informativeText = message; alert.runModal()
    NSApp.terminate(nil)
  }
}

if CommandLine.arguments.contains("--verify-downloads-only") {
  do { try verifyDownloadsAccess(); exit(0) } catch { fputs("Downloads access failed: \(error)\n", stderr); exit(1) }
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let launcher = Launcher()
application.delegate = launcher
application.run()
