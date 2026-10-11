import UIKit
import Network

struct RelayEvent: Codable {
    let id: String
    let kind: String
    var data: String? = nil
    var origin: String? = nil
}

@MainActor
final class ByteProxy {
    private final class Peer {
        let connection = NWConnection(host: "127.0.0.1", port: 53317, using: .tcp)
        var sent = 0
        var received = 0
        var inputEOF = false
        var outputEOF = false
    }
    private let queue = DispatchQueue(label: "issue1591.byteproxy")
    private var peers: [String: Peer] = [:]
    private var session: URLSession?
    private var pollTask: Task<Void, Never>?
    private var timer: Timer?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var started = ProcessInfo.processInfo.systemUptime
    private var baseURL: URL?
    private var token = ""
    private var generation = UUID()
    private(set) var running = false
    var logLine: ((String) -> Void)?

    func log(_ event: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let budget = UIApplication.shared.backgroundTimeRemaining
        let remaining = budget > 86400 ? "unbounded-foreground" : String(format: "%.3f", budget)
        let line = String(format: "elapsed=%.3f", elapsed) + " remaining=" + remaining + " " + event
        NSLog("%@", line)
        logLine?(line)
    }

    func start(urlText: String, token: String) {
        guard !running else { return }
        guard let url = URL(string: urlText), ["http", "https"].contains(url.scheme ?? ""),
              url.host != nil, url.user == nil, url.password == nil, url.query == nil,
              url.fragment == nil, url.path.isEmpty || url.path == "/", !token.isEmpty else {
            log("configuration-invalid: use a relay origin and nonempty token")
            return
        }
        started = ProcessInfo.processInfo.systemUptime
        generation = UUID()
        self.baseURL = url
        self.token = token
        running = true
        // Request the finite budget while this app is still in the foreground.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Issue1591ByteProxy") { [weak self] in
            Task { @MainActor in
                self?.log("background-expired")
                self?.stop(reason: "background-expired")
            }
        }
        guard backgroundTask != .invalid else {
            stop(reason: "background-task-unavailable")
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        log("started destination=127.0.0.1:53317")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.log("budget-sample") }
        }
        pollTask = Task { [weak self] in await self?.poll() }
    }

    func stop(reason: String) {
        guard running else { return }
        log("stopping reason=" + reason)
        running = false
        timer?.invalidate()
        timer = nil
        pollTask?.cancel()
        pollTask = nil
        for (id, peer) in peers {
            log("closed id=\(id) toLocalSend=\(peer.sent) fromLocalSend=\(peer.received)")
            peer.connection.cancel()
        }
        peers.removeAll()
        session?.invalidateAndCancel()
        session = nil
        token = ""
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        log("stopped")
    }

    private func request(path: String, event: RelayEvent? = nil) async throws -> Data {
        guard running, let session, let baseURL else { throw CancellationError() }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let event {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(event)
        }
        let (data, response) = try await session.data(for: request)
        guard running, session === self.session else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ProxyFailure.relayStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func poll() async {
        let run = generation
        do {
            while running && !Task.isCancelled {
                let data = try await request(path: "pull")
                let events = try JSONDecoder().decode([RelayEvent].self, from: data)
                log("poll events=\(events.count)")
                for event in events {
                    guard running else { return }
                    try await consume(event)
                }
            }
        } catch {
            if running && generation == run { logError(error, event: "relay-poll-failed"); stop(reason: "relay-poll-failed") }
        }
    }

    private func consume(_ event: RelayEvent) async throws {
        if event.kind == "open" {
            guard peers[event.id] == nil else { throw ProxyFailure.protocolViolation }
            let peer = Peer()
            peers[event.id] = peer
            log("open id=\(event.id)")
            peer.connection.stateUpdateHandler = { [weak self, weak peer] state in
                Task { @MainActor in
                    guard let self, let peer, self.peers[event.id] === peer else { return }
                    switch state {
                    case .ready:
                        self.log("loopback-ready id=\(event.id)")
                        self.receive(id: event.id, peer: peer)
                    case .failed(let error):
                        await self.failPeer(id: event.id, peer: peer, error: error)
                    default: break
                    }
                }
            }
            peer.connection.start(queue: queue)
            return
        }
        guard let peer = peers[event.id] else {
            // The relay can close after the local peer has already failed.
            if event.kind == "close" || event.kind == "error" { return }
            throw ProxyFailure.protocolViolation
        }
        switch event.kind {
        case "data":
            guard !peer.inputEOF, let encoded = event.data, let bytes = Data(base64Encoded: encoded) else {
                throw ProxyFailure.protocolViolation
            }
            try await send(bytes, final: false, peer: peer)
            peer.sent += bytes.count
            log("toLocalSend id=\(event.id) bytes=\(bytes.count) total=\(peer.sent)")
        case "eof":
            guard !peer.inputEOF else { throw ProxyFailure.protocolViolation }
            try await send(nil, final: true, peer: peer)
            peer.inputEOF = true
            log("sender-eof id=\(event.id)")
            finishIfComplete(id: event.id, peer: peer)
        case "close", "error":
            close(id: event.id, peer: peer, reason: event.kind)
        default: throw ProxyFailure.protocolViolation
        }
    }

    private func send(_ bytes: Data?, final: Bool, peer: Peer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.connection.send(content: bytes, contentContext: final ? .finalMessage : .defaultMessage,
                                 isComplete: final, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func receive(id: String, peer: Peer) {
        let run = generation
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak peer] data, _, complete, error in
            Task { @MainActor in
                guard let self, let peer, self.running, self.peers[id] === peer else { return }
                do {
                    if let data, !data.isEmpty {
                        _ = try await self.request(path: "push", event: RelayEvent(id: id, kind: "data", data: data.base64EncodedString()))
                        peer.received += data.count
                        self.log("fromLocalSend id=\(id) bytes=\(data.count) total=\(peer.received)")
                    }
                    if let error { await self.failPeer(id: id, peer: peer, error: error); return }
                    if complete {
                        _ = try await self.request(path: "push", event: RelayEvent(id: id, kind: "eof"))
                        peer.outputEOF = true
                        self.log("local-eof id=\(id)")
                        self.finishIfComplete(id: id, peer: peer)
                    } else if self.peers[id] === peer {
                        self.receive(id: id, peer: peer)
                    }
                } catch {
                    if self.running && self.generation == run { self.logError(error, event: "relay-push-failed"); self.stop(reason: "relay-push-failed") }
                }
            }
        }
    }

    private func failPeer(id: String, peer: Peer, error: Error) async {
        guard peers[id] === peer else { return }
        let run = generation
        logError(error, event: "loopback-failed id=" + id)
        close(id: id, peer: peer, reason: "loopback-failed")
        do { _ = try await request(path: "push", event: RelayEvent(id: id, kind: "error", origin: "ios-loopback")) }
        catch { if running && generation == run { logError(error, event: "error-notification-failed"); stop(reason: "error-notification-failed") } }
    }

    private func finishIfComplete(id: String, peer: Peer) {
        if peer.inputEOF && peer.outputEOF { close(id: id, peer: peer, reason: "both-eof") }
    }

    private func close(id: String, peer: Peer, reason: String) {
        guard peers[id] === peer else { return }
        peers.removeValue(forKey: id)
        peer.connection.cancel()
        log("closed id=\(id) reason=\(reason) toLocalSend=\(peer.sent) fromLocalSend=\(peer.received)")
    }

    private func logError(_ error: Error, event: String) {
        // Do not use localizedDescription: URLSession errors can include request URLs.
        let nsError = error as NSError
        log(event + " domain=" + nsError.domain + " code=" + String(nsError.code))
    }
}

private enum ProxyFailure: Error { case relayStatus(Int), protocolViolation }

@MainActor
final class ProxyViewController: UIViewController {
    let proxy = ByteProxy()
    private let urlField = UITextField()
    private let tokenField = UITextField()
    private let logView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Issue 1591 byte proxy"
        urlField.placeholder = "Relay origin, e.g. http://bs-local.com:8080"
        urlField.accessibilityIdentifier = "relayURL"
        urlField.accessibilityLabel = "Relay origin"
        urlField.keyboardType = .URL
        tokenField.placeholder = "Relay token"
        tokenField.accessibilityIdentifier = "relayToken"
        tokenField.accessibilityLabel = "Relay token"
        tokenField.isSecureTextEntry = true
        for field in [urlField, tokenField] {
            field.borderStyle = .roundedRect
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        let start = UIButton(type: .system)
        start.setTitle("Start proxy", for: .normal)
        start.accessibilityIdentifier = "startProxy"
        start.addTarget(self, action: #selector(startProxy), for: .touchUpInside)
        let stop = UIButton(type: .system)
        stop.setTitle("Stop proxy", for: .normal)
        stop.accessibilityIdentifier = "stopProxy"
        stop.addTarget(self, action: #selector(stopProxy), for: .touchUpInside)
        let note = UILabel()
        note.text = "Start before switching to LocalSend. iOS can expire the background budget."
        note.numberOfLines = 0
        logView.isEditable = false
        logView.accessibilityIdentifier = "proxyLog"
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let stack = UIStackView(arrangedSubviews: [note, urlField, tokenField, start, stop, logView])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
        proxy.logLine = { [weak self] line in
            guard let self else { return }
            self.logView.text += line + "\n"
            // Keep the UI bounded; the device log retains the complete record.
            if self.logView.text.count > 24000 { self.logView.text = String(self.logView.text.suffix(16000)) }
        }
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        urlField.text = value("--relay-url")
        tokenField.text = value("--relay-token")
        if args.contains("--start-proxy") { startProxy() }
    }

    @objc private func startProxy() {
        view.endEditing(true)
        proxy.start(urlText: urlField.text ?? "", token: tokenField.text ?? "")
    }
    @objc private func stopProxy() { proxy.stop(reason: "user-stop") }
}

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let controller = ProxyViewController()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UINavigationController(rootViewController: controller)
        window?.makeKeyAndVisible()
        return true
    }
    func applicationDidEnterBackground(_ application: UIApplication) { controller.proxy.log("did-enter-background") }
    func applicationWillEnterForeground(_ application: UIApplication) { controller.proxy.log("will-enter-foreground") }
    func applicationWillTerminate(_ application: UIApplication) { controller.proxy.stop(reason: "termination") }
}
