import UIKit
import CryptoKit

// Synthetic route qualification only. This owner never creates a LocalSend peer.
private final class QualificationDelegate: NSObject, URLSessionWebSocketDelegate {
    weak var owner: WebSocketQualification?
    let generation: UUID
    init(owner: WebSocketQualification, generation: UUID) {
        self.owner = owner
        self.generation = generation
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.opened(session: session, task: webSocketTask, run: self.generation)
        }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.closed(session: session, task: webSocketTask, run: self.generation, code: closeCode)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.completed(session: session, task: task, run: self.generation, error: error)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never allow the authentication header to follow a redirect.
        completionHandler(nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.redirected(session: session, task: task, run: self.generation)
        }
    }
}

@MainActor
final class WebSocketQualification {
    private struct Receipt {
        let uptime: Double
        let boundary: String
        let ordinal: Int
        let bytes: Int
        let hash: String
        let state: String
        let budgetState: String
        let remaining: Double?
    }
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var delegate: QualificationDelegate?
    private var sequence: Task<Void, Never>?
    private var timer: Timer?
    private var assertion = UIBackgroundTaskIdentifier.invalid
    private var generation = UUID()
    private var qualificationID = ""
    private var started = 0.0
    private var deadline = 0.0
    private var phaseDeadline = 0.0
    private var didOpen = false
    private var backgroundObserved = false
    private var waitingClose = false
    private var completeSendFinished = false
    private var normalCloseReceived = false
    private var records: [Receipt] = []
    private var dropped = 0
    private var sentFrames = 0
    private var receivedFrames = 0
    private var sentBytes = 0
    private var receivedBytes = 0
    private var sentBinary = 0
    private var receivedBinary = 0
    private var sendInFlight = false
    private var receiveInFlight = false
    private let challenges = (1...4).map { Data(repeating: UInt8($0), count: 1024) }
    private(set) var running = false
    var logLine: ((String) -> Void)?

    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var state: String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
    private var allowance: Double? {
        let value = UIApplication.shared.backgroundTimeRemaining
        return value.isFinite && value != .greatestFiniteMagnitude ? value : nil
    }
    private func output(_ line: String) { NSLog("%@", line); logLine?(line) }
    private func record(_ boundary: String, ordinal: Int = 0, data: Data? = nil) {
        guard records.count < 128 else { dropped += 1; return }
        let budget = allowance
        records.append(Receipt(uptime: now, boundary: String(boundary.prefix(256)), ordinal: ordinal,
                               bytes: data?.count ?? 0,
                               hash: data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "-",
                               state: state, budgetState: budget == nil ? "foreground-unbounded" : "finite", remaining: budget))
    }
    private func current(_ task: URLSessionTask, _ session: URLSession, _ run: UUID) -> Bool {
        running && generation == run && task === socket && session === self.session
    }
    private func check(_ task: URLSessionWebSocketTask, _ run: UUID, background: Bool = false) throws {
        guard running, generation == run, task === socket, !Task.isCancelled else { throw CancellationError() }
        guard now < deadline, now < phaseDeadline else { throw Failure.deadline }
        guard dropped == 0, assertion != .invalid else { throw Failure.bound }
        if background {
            guard backgroundObserved, state == "background", let remaining = allowance, remaining > 0 else { throw Failure.lifecycle }
        }
    }

    func start(urlText: String, token: String, id: String) {
        guard !running else { return }
        guard let origin = URLComponents(string: urlText), origin.scheme == "http", origin.host == "bs-local.com",
              origin.port == 8080, origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/", !token.isEmpty, token.count <= 256,
              !token.contains("\r"), !token.contains("\n"), !id.isEmpty, id.utf8.count <= 128,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }), state == "active" else {
            output("ws-configuration-invalid"); return
        }
        generation = UUID(); qualificationID = id; started = now; deadline = started + 15; phaseDeadline = started + 5
        didOpen = false; backgroundObserved = false; waitingClose = false; completeSendFinished = false; normalCloseReceived = false; dropped = 0
        sentFrames = 0; receivedFrames = 0; sentBytes = 0; receivedBytes = 0; sentBinary = 0; receivedBinary = 0
        sendInFlight = false; receiveInFlight = false; records.removeAll(keepingCapacity: true); records.reserveCapacity(128)
        running = true
        let run = generation
        assertion = UIApplication.shared.beginBackgroundTask(withName: "Issue1591WSQualification") { [weak self] in
            Task { @MainActor in
                guard let self, self.running, self.generation == run else { return }
                self.stop(reason: "background-expired")
            }
        }
        guard assertion != .invalid else { stop(reason: "assertion-unavailable"); return }
        record("upgrade-prepare")
        var endpoint = origin; endpoint.scheme = "ws"; endpoint.path = "/qualify-ws"
        guard let url = endpoint.url else { stop(reason: "configuration-invalid"); return }
        var request = URLRequest(url: url); request.timeoutInterval = 5
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(id, forHTTPHeaderField: "X-Qualification-Id")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = QualificationDelegate(owner: self, generation: run)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request); task.maximumMessageSize = 8192
        self.delegate = delegate; self.session = session; socket = task
        armTimer(seconds: 5, reason: "open-deadline")
        record("upgrade-invoke"); task.resume()
    }
    private func armTimer(seconds: Double, reason: String) {
        timer?.invalidate()
        let run = generation
        timer = Timer.scheduledTimer(withTimeInterval: max(0.001, seconds), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, self.generation == run else { return }
                self.stop(reason: reason)
            }
        }
    }
    func enteredBackground() {
        guard running else { return }
        guard now < deadline, now < phaseDeadline else { stop(reason: "late-background"); return }
        guard assertion != .invalid, state == "background", let remaining = allowance, remaining >= 5 else {
            stop(reason: "background-allowance-invalid"); return
        }
        backgroundObserved = state == "background"
        record("did-enter-background")
    }
    func enteringForeground() { if running { stop(reason: "foreground-return") } }
    fileprivate func opened(session: URLSession, task: URLSessionWebSocketTask, run: UUID) {
        guard current(task, session, run) else { return }
        do { try check(task, run) } catch { stop(reason: "late-open"); return }
        guard !didOpen else { stop(reason: "duplicate-open"); return }
        didOpen = true; phaseDeadline = min(deadline, now + 10)
        record("upgrade-open"); armTimer(seconds: phaseDeadline - now, reason: "sequence-deadline")
        sequence = Task { [weak self] in await self?.transcript(task: task, run: run) }
    }
    private func control(_ kind: String) throws -> String {
        let remaining = allowance
        var value: [String: Any] = ["v": 1, "id": qualificationID, "kind": kind,
                                  "pid": ProcessInfo.processInfo.processIdentifier, "generation": generation.uuidString,
                                  "state": state, "budgetState": remaining == nil ? "foreground-unbounded" : "finite",
                                  "remainingBudgetSeconds": remaining.map { $0 as Any } ?? NSNull(), "assertionActive": assertion != .invalid]
        if kind == "native-complete" { value["sentBinary"] = sentBinary; value["receivedBinary"] = receivedBinary; value["outcome"] = "passed" }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 1024, let text = String(data: data, encoding: .utf8) else { throw Failure.bound }
        return text
    }
    private func send(_ message: URLSessionWebSocketTask.Message, task: URLSessionWebSocketTask, run: UUID,
                      ordinal: Int = 0, background: Bool, foregroundCompletionRequired: Bool = true) async throws {
        try check(task, run, background: background)
        if !background, state != "active" { throw Failure.lifecycle }
        let data: Data?
        let bytes: Int
        switch message { case .data(let value): data = value; bytes = value.count
        case .string(let value): data = nil; bytes = value.utf8.count
        @unknown default: throw Failure.protocolViolation }
        guard !sendInFlight, bytes <= (data == nil ? 1024 : 4096), sentFrames < 16, sentBytes + bytes <= 65536 else { throw Failure.bound }
        sendInFlight = true; sentFrames += 1; sentBytes += bytes
        record("send-invoke", ordinal: ordinal, data: data)
        defer { if generation == run { sendInFlight = false } }
        try await task.send(message)
        try check(task, run, background: background)
        if !background, foregroundCompletionRequired, state != "active" { throw Failure.lifecycle }
        if !background, !foregroundCompletionRequired, state != "active" {
            if state == "background" { try check(task, run, background: true) }
            else if state != "inactive" { throw Failure.lifecycle }
        }
        if data != nil { sentBinary += 1 }
        record("send-completion", ordinal: ordinal, data: data)
    }
    private func receive(ordinal: Int, task: URLSessionWebSocketTask, run: UUID, background: Bool) async throws {
        try check(task, run, background: background)
        if !background, state != "active" { throw Failure.lifecycle }
        guard !receiveInFlight else { throw Failure.bound }
        receiveInFlight = true
        defer { if generation == run { receiveInFlight = false } }
        let message = try await task.receive()
        try check(task, run, background: background)
        if !background, state != "active" { throw Failure.lifecycle }
        guard receivedFrames < 16, case .data(let data) = message, data.count <= 4096,
              receivedBytes + data.count <= 65536 else { throw Failure.protocolViolation }
        receivedFrames += 1; receivedBytes += data.count
        record("receive", ordinal: ordinal, data: data)
        guard data == challenges[ordinal - 1] else { throw Failure.protocolViolation }
        receivedBinary += 1
    }
    private func transcript(task: URLSessionWebSocketTask, run: UUID) async {
        do {
            try check(task, run)
            guard state == "active", allowance == nil || (allowance ?? 0) > 0 else { throw Failure.lifecycle }
            try await send(.string(control("foreground-ready")), task: task, run: run, background: false)
            try await send(.data(challenges[0]), task: task, run: run, ordinal: 1, background: false)
            try await receive(ordinal: 1, task: task, run: run, background: false)
            guard state == "active" else { throw Failure.lifecycle }
            record("foreground-echo-verified", ordinal: 1)
            record("foreground-verified-invoke")
            try await send(.string(control("foreground-verified")), task: task, run: run, background: false, foregroundCompletionRequired: false)
            record("foreground-verified-completion")
            while !backgroundObserved {
                try check(task, run)
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try check(task, run, background: true)
            guard let remaining = allowance, remaining >= 5 else { throw Failure.lifecycle }
            try await send(.string(control("background-ready")), task: task, run: run, background: true)
            try await send(.data(challenges[1]), task: task, run: run, ordinal: 2, background: true)
            try await receive(ordinal: 2, task: task, run: run, background: true)
            for ordinal in 3...4 {
                try await receive(ordinal: ordinal, task: task, run: run, background: true)
                try await send(.data(challenges[ordinal - 1]), task: task, run: run, ordinal: ordinal, background: true)
            }
            // The peer may close before the local send completion callback is delivered.
            waitingClose = true
            phaseDeadline = min(phaseDeadline, now + 1)
            armTimer(seconds: phaseDeadline - now, reason: "normal-close-missing")
            try await send(.string(control("native-complete")), task: task, run: run, background: true)
            completeSendFinished = true; record("await-normal-close")
            if normalCloseReceived { finish(outcome: "passed", reason: "normal-close", normalClose: true); return }
            // Keep one receive pending: an extra application frame is a fatal transcript violation.
            receiveInFlight = true
            _ = try await task.receive()
            if running, generation == run { stop(reason: "unexpected-extra-frame") }
        } catch {
            guard running, generation == run, task === socket else { return }
            receiveInFlight = false
            // A peer Close makes receive fail; only didClose(1000) can pass the close gate.
            if waitingClose && completeSendFinished && now < deadline && now < phaseDeadline {
                record("receive-ended-await-close"); return
            }
            let value = error as NSError
            record("sequence-error-domain-" + String(value.domain.prefix(128)) + "-code-" + String(value.code))
            stop(reason: "sequence-failed")
        }
    }
    fileprivate func closed(session: URLSession, task: URLSessionWebSocketTask, run: UUID, code: URLSessionWebSocketTask.CloseCode) {
        guard current(task, session, run) else { return }
        do { try check(task, run, background: true) } catch { stop(reason: "late-or-foreground-close"); return }
        record("close-receipt-code-" + String(code.rawValue))
        guard waitingClose, code == .normalClosure, sentBinary == 4, receivedBinary == 4, dropped == 0 else {
            finish(outcome: "failed", reason: "unexpected-close", normalClose: code == .normalClosure); return
        }
        normalCloseReceived = true
        if completeSendFinished { finish(outcome: "passed", reason: "normal-close", normalClose: true) }
    }
    fileprivate func completed(session: URLSession, task: URLSessionTask, run: UUID, error: Error?) {
        guard current(task, session, run) else { return }
        guard now < deadline, now < phaseDeadline else { stop(reason: "late-task-completion"); return }
        record("task-completion")
        if let error {
            let value = error as NSError
            record("task-error-domain-" + String(value.domain.prefix(128)) + "-code-" + String(value.code))
        }
        if !waitingClose { stop(reason: "task-ended-before-close") }
    }
    fileprivate func redirected(session: URLSession, task: URLSessionTask, run: UUID) {
        guard current(task, session, run) else { return }
        record("redirect-refused"); stop(reason: "redirect-refused")
    }
    func stop(reason: String) { if running { finish(outcome: "failed", reason: reason, normalClose: false) } }
    private func finish(outcome: String, reason: String, normalClose: Bool) {
        guard running else { return }
        record(normalClose ? "normal-close-dispose" : "forced-cancel")
        running = false; timer?.invalidate(); timer = nil; sequence?.cancel(); sequence = nil
        socket?.cancel(with: normalClose ? .normalClosure : .goingAway, reason: nil)
        session?.invalidateAndCancel(); socket = nil; session = nil
        delegate?.owner = nil; delegate = nil; sendInFlight = false; receiveInFlight = false
        if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion); assertion = .invalid }
        record("allowance-ended")
        output("ws-summary id=\(qualificationID) generation=\(generation.uuidString) pid=\(ProcessInfo.processInfo.processIdentifier) outcome=\(dropped == 0 ? outcome : "failed") reason=\(String(reason.prefix(256))) originUptime=\(started) sentBinary=\(sentBinary) receivedBinary=\(receivedBinary) sentFrames=\(sentFrames) receivedFrames=\(receivedFrames) sentBytes=\(sentBytes) receivedBytes=\(receivedBytes) records=\(records.count) dropped=\(dropped) task=0 session=0 queue=0 sendInFlight=0 receiveInFlight=0 assertionEnded=true normalClose=\(normalClose) forced=\(!normalClose)")
        for receipt in records {
            output("ws-record id=\(qualificationID) generation=\(generation.uuidString) uptime=\(receipt.uptime) boundary=\(receipt.boundary) ordinal=\(receipt.ordinal) bytes=\(receipt.bytes) hash=\(receipt.hash) state=\(receipt.state) budgetState=\(receipt.budgetState) remainingBudgetSeconds=\(receipt.remaining.map { String($0) } ?? "null")")
        }
        // Terminal transcript remains bounded and retained until the next explicit start.
        qualificationID = ""
    }
    private enum Failure: Error { case deadline, bound, lifecycle, protocolViolation }
}
