import Foundation
import Network

final class TS890Connection {
    enum Status: String { case disconnected, connecting, authenticating, connected }
    private enum AuthState { case idle, sentCN, sentID, authenticated }

    var onStatusChange: ((Status) -> Void)?
    var onError: ((String) -> Void)?
    var onFrame: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var status: Status = .disconnected
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "TS890Connection.queue")
    private var receiveBuffer = Data()
    private var authState: AuthState = .idle
    private var useKnsLogin: Bool = true
    private var accountType: KenwoodKNS.AccountType = .administrator
    private var adminId: String = ""
    private var adminPassword: String = ""
    private var authTimeoutTimer: DispatchSourceTimer?
    private var connectTimeoutTimer: DispatchSourceTimer?
    private var keepaliveTimer: DispatchSourceTimer?
    private let keepaliveInterval: TimeInterval = 5
    private let authTimeoutInterval: TimeInterval = 10
    private let connectTimeoutInterval: TimeInterval = 15
    private var currentHost: String?

    private func isASCII(_ s: String) -> Bool {
        s.utf8.allSatisfy { $0 < 0x80 }
    }

    private func sanitizeCredential(_ s: String) -> String {
        // Copy/paste from password managers often includes trailing newline/space.
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }

    private func redactedForLog(_ command: String) -> String {
        // Avoid leaking admin password into the on-screen log.
        if command.hasPrefix("##ID") { return "##ID<redacted>;" }
        return command
    }

    /// Silently tears down any existing connection without firing status callbacks.
    /// Used by connect() so the internal cleanup doesn't produce a spurious .disconnected
    /// event that races with the subsequent .connecting / .connected events.
    private func teardown() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        stopAuthTimeout()
        stopConnectTimeout()
        stopKeepalive()
        authState = .idle
    }

    func connect(host: String, port: UInt16, useKnsLogin: Bool, accountType: KenwoodKNS.AccountType = .administrator, adminId: String, adminPassword: String) {
        teardown()
        status = .connecting
        onStatusChange?(status)
        onLog?("Connecting to \(host):\(port)")
        self.useKnsLogin = useKnsLogin
        self.accountType = accountType
        self.adminId = sanitizeCredential(adminId)
        self.adminPassword = sanitizeCredential(adminPassword)
        self.currentHost = host

        if useKnsLogin {
            // Per Kenwood: account + password lengths are 01..32 characters.
            if self.adminId.isEmpty || self.adminPassword.isEmpty {
                onError?("KNS login requires an administrator ID and password")
                status = .disconnected
                onStatusChange?(status)
                return
            }
            if !isASCII(self.adminId) || !isASCII(self.adminPassword) {
                onError?("KNS login currently supports ASCII administrator ID/password only")
                status = .disconnected
                onStatusChange?(status)
                return
            }
            if self.adminId.utf8.count > 32 || self.adminPassword.utf8.count > 32 {
                onError?("KNS login credentials must be 32 characters or fewer")
                status = .disconnected
                onStatusChange?(status)
                return
            }
        }

        let endpointHost = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            onError?("Invalid port")
            status = .disconnected
            onStatusChange?(status)
            return
        }
        let connection = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .waiting(let error):
                self.onLog?("Connection waiting: \(error.localizedDescription)")
                self.onError?("Waiting: \(error.localizedDescription)")
            case .ready:
                self.stopConnectTimeout()
                self.receiveLoop()
                if self.useKnsLogin {
                    self.authState = .sentCN
                    self.status = .authenticating
                    self.onStatusChange?(self.status)
                    self.onLog?("KNS: Sending ##CN")
                    self.send(KenwoodKNS.knsConnect())
                    self.startAuthTimeout()
                } else {
                    self.status = .connected
                    self.onStatusChange?(self.status)
                    self.onLog?("Connected without KNS login")
                    self.onLog?("Enabling Auto Information (AI)")
                    self.send(KenwoodCAT.setAutoInformation(.onNonPersistent))
                    self.startKeepalive()
                }
            case .failed(let error):
                self.stopConnectTimeout()
                self.onLog?("Connection failed: \(error.localizedDescription)")
                self.onError?("Connection failed: \(error.localizedDescription)")
                self.disconnect()
            case .cancelled:
                self.stopConnectTimeout()
                self.onLog?("Connection cancelled")
                self.disconnect()
            default:
                break
            }
        }
        connection.start(queue: queue)
        startConnectTimeout()
    }

    func disconnect() {
        teardown()
        status = .disconnected
        onStatusChange?(status)
        onLog?("Disconnected")
    }

    func send(_ command: String) {
        guard let connection else {
            onError?("Not connected")
            return
        }
        let data = Data(command.utf8)
        onLog?("TX: \(redactedForLog(command))")
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.onError?("Send failed: \(error.localizedDescription)")
            }
        })
    }

    private func receiveLoop() {
        // Capture the specific NWConnection so stale completion handlers from a
        // previously-cancelled connection don't accidentally act on the new one.
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === conn else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.flushFrames()
            }
            if let error {
                self.onError?("Receive failed: \(error.localizedDescription)")
                self.disconnect()
                return
            }
            if isComplete {
                self.disconnect()
                return
            }
            self.receiveLoop()
        }
    }

    private func flushFrames() {
        while let separatorRange = receiveBuffer.firstRange(of: Data([UInt8(ascii: ";")])) {
            let frameData = receiveBuffer.subdata(in: 0..<separatorRange.lowerBound)
            receiveBuffer.removeSubrange(0...separatorRange.lowerBound)
            let frame: String
            if let decoded = String(data: frameData, encoding: .utf8) {
                frame = decoded
            } else if let decoded = String(data: frameData, encoding: .isoLatin1) {
                // Per Kenwood: bytes 0x80..0xFF depend on keyboard language (Menu 9-01).
                frame = decoded
            } else {
                // Worst case: preserve something useful for debugging rather than dropping.
                frame = String(decoding: frameData, as: UTF8.self)
            }
            do {
                // Some radios/bridges insert CR/LF (or other control bytes) between frames.
                // Normalize so auth parsing and command routing doesn't break.
                let cleaned = frame.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                guard !cleaned.isEmpty else { continue }
                let fullFrame = cleaned.hasSuffix(";") ? cleaned : (cleaned + ";")

                // AI can cause high-rate and/or huge frames (e.g. bandscope ##DD2/##DD3).
                // Avoid pushing giant strings into the UI log, and skip onFrame for those until we need them.
                if fullFrame.hasPrefix("##DD2") || fullFrame.hasPrefix("##DD3") {
                    onLog?("RX: \(fullFrame.prefix(5))... (\(fullFrame.count) chars)")
                    handleAuthFrame(fullFrame)
                    continue
                }

                onLog?("RX: \(fullFrame)")
                handleAuthFrame(fullFrame)
                onFrame?(fullFrame)
            }
        }
    }

    private func handleAuthFrame(_ frame: String) {
        let normalized = frame.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        switch authState {
        case .sentCN:
            // Only proceed when we get an explicit CN response.
            if normalized.hasPrefix("##CN1") {
                authState = .sentID
                onLog?("KNS: Sending ##ID")
                send(KenwoodKNS.knsLogin(accountType: accountType, account: adminId, password: adminPassword))
            } else if normalized.hasPrefix("##CN0") {
                onLog?("KNS: Connect rejected")
                onError?("KNS connect rejected (##CN0)")
                disconnect()
            }
        case .sentID:
            if normalized.hasPrefix("##ID1") {
                authState = .authenticated
                stopAuthTimeout()
                status = .connected
                onStatusChange?(status)
                onLog?("KNS: Authenticated")
                onLog?("Enabling Auto Information (AI)")
                send(KenwoodCAT.setAutoInformation(.onNonPersistent))
                startKeepalive()
            } else if normalized.hasPrefix("##ID0") {
                onLog?("KNS: Authentication failed")
                onError?("KNS authentication failed — check Admin ID and password")
                disconnect()
            }
        default:
            break
        }
    }

    private func startConnectTimeout() {
        stopConnectTimeout()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + connectTimeoutInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.status == .connecting else { return }
            let host = self.currentHost ?? "unknown"
            self.onError?("Connection timed out — radio unreachable at \(host)")
            self.disconnect()
        }
        connectTimeoutTimer = timer
        timer.resume()
    }

    private func stopConnectTimeout() {
        connectTimeoutTimer?.cancel()
        connectTimeoutTimer = nil
    }

    private func startAuthTimeout() {
        stopAuthTimeout()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + authTimeoutInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.authState != .authenticated {
                self.onLog?("KNS: Authentication timed out")
                self.onError?("KNS authentication timed out")
                self.disconnect()
            }
        }
        authTimeoutTimer = timer
        timer.resume()
    }

    private func stopAuthTimeout() {
        authTimeoutTimer?.cancel()
        authTimeoutTimer = nil
    }

    private func startKeepalive() {
        stopKeepalive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + keepaliveInterval, repeating: keepaliveInterval)
        timer.setEventHandler { [weak self] in
            self?.send(KenwoodCAT.getVFOAFrequency())
        }
        keepaliveTimer = timer
        timer.resume()
    }

    private func stopKeepalive() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }
}
