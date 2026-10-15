import Foundation

enum RealtimeWebSocketClientError: LocalizedError {
    case invalidURL
    case notConnected
    case encodeFailed
    case activeSessionInterrupted

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The backend URL is invalid."
        case .notConnected:
            return "WebSocket is not connected."
        case .encodeFailed:
            return "Failed to encode websocket message."
        case .activeSessionInterrupted:
            return "The dictation connection dropped unexpectedly."
        }
    }
}

enum RealtimeConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case sleeping
    case connected
    case reconnecting(Int)
}

protocol RealtimeWebSocketClientDelegate: AnyObject {
    func websocketClient(_ client: RealtimeWebSocketClient, didUpdate state: RealtimeConnectionState)
    func websocketClient(_ client: RealtimeWebSocketClient, didReceive message: ServerMessage)
    func websocketClient(_ client: RealtimeWebSocketClient, didFail error: Error)
    // Emitted when the backend rejected auth (close code .policyViolation). The delegate
    // should force-refresh the auth token so reconfiguration lifts the reconnect suppression.
    func websocketClientDidRejectAuthorization(_ client: RealtimeWebSocketClient)
}

extension RealtimeWebSocketClientDelegate {
    func websocketClientDidRejectAuthorization(_ client: RealtimeWebSocketClient) {}
}

enum RealtimeOutgoingMessageDisposition: Equatable {
    case sendNow
    case bufferUntilSessionStartAcknowledgement
    case drop
}

func realtimeOutgoingMessageDisposition(
    for messageType: ClientMessageType,
    awaitingSessionStartAcknowledgement: Bool,
    dropStreamingMessagesUntilNextSessionStart: Bool
) -> RealtimeOutgoingMessageDisposition {
    if dropStreamingMessagesUntilNextSessionStart {
        switch messageType {
        case .sessionStart:
            return .sendNow
        case .audioChunk, .sessionEnd, .ping:
            return .drop
        }
    }

    if awaitingSessionStartAcknowledgement {
        switch messageType {
        case .audioChunk, .sessionEnd:
            return .bufferUntilSessionStartAcknowledgement
        case .sessionStart, .ping:
            return .sendNow
        }
    }

    return .sendNow
}

private enum RealtimeStreamingSessionState: Equatable {
    case idle
    case live
    case finalizing

    var isActive: Bool {
        self != .idle
    }

    var debugDescription: String {
        switch self {
        case .idle:
            return "idle"
        case .live:
            return "live"
        case .finalizing:
            return "finalizing"
        }
    }
}

struct RealtimeWebSocketDebugSnapshot: Sendable {
    let connectionState: String
    let streamingSessionState: String
    let currentClientSessionID: String?
    let currentConnectionID: String?
    let awaitingSessionStartAcknowledgement: Bool
    let pendingTransportMessageCount: Int
    let pendingStreamingMessageCount: Int
    let dropStreamingMessagesUntilNextSessionStart: Bool
    let lastCloseCode: Int?
    let lastCloseReason: String?
}

/// Pure liveness policy: recycle the connection when no inbound frame has arrived
/// for more than two ping intervals (any frame proves the socket is alive, not just pong).
enum RealtimeLivenessPolicy {
    static func shouldRecycle(
        now: TimeInterval,
        lastInboundAt: TimeInterval,
        pingInterval: TimeInterval
    ) -> Bool {
        guard pingInterval > 0 else { return false }
        return (now - lastInboundAt) > (pingInterval * 2)
    }
}

/// All mutable state is confined to `stateQueue`. Every public entry point hops onto the
/// queue; internal cross-calls run the private on-queue bodies directly. The URLSession
/// delegate queue is backed by `stateQueue`, so delegate + receive/send completion callbacks
/// are serialized with our own mutations — no locks needed (C-2).
// All mutable state is confined to `stateQueue` (see below), so cross-thread capture is safe (C-2).
final class RealtimeWebSocketClient: NSObject, @unchecked Sendable {
    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private var reconnectAttempts = 0
    private var shouldMaintainConnection = true
    private var suppressReconnectUntilReconfigure = false
    private var backendURL: URL?
    private var authToken = ""
    private var pingTimer: DispatchSourceTimer?
    private var lastInboundAt: TimeInterval = 0
    // Enforce the liveness recycle only once the server has proven it responds to traffic on
    // this connection (any inbound frame), so we never loop-recycle a healthy idle connection
    // against a backend that doesn't echo idle pings.
    private var hasObservedInboundOnConnection = false
    private var pendingMessages: [ClientMessage] = []
    private var pendingStreamingMessagesAwaitingSessionStartAcknowledgement: [ClientMessage] = []
    private var streamingSessionState: RealtimeStreamingSessionState = .idle
    private var dropStreamingMessagesUntilNextSessionStart = false
    private var isAwaitingSessionStartAcknowledgement = false
    private var currentClientSessionID: String?
    private var currentConnectionID: String?
    private var lastCloseCode: URLSessionWebSocketTask.CloseCode?
    private var lastCloseReason: String?
    private var pendingLegacySessionStartAcknowledgementWorkItem: DispatchWorkItem?
    private var lastFailureDebugSnapshot: RealtimeWebSocketDebugSnapshot?

    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()
    private let stateQueue = DispatchQueue(label: "dictation.websocket.state")
    private let delegateOperationQueue: OperationQueue
    private let pingInterval: TimeInterval = 15
    private let sessionStartAcknowledgementFallbackDelay: TimeInterval = 0.25

    weak var delegate: RealtimeWebSocketClientDelegate?

    // Written and read only on stateQueue; mirrored to the delegate via didUpdate.
    private var state: RealtimeConnectionState = .disconnected {
        didSet {
            guard state != oldValue else { return }
            delegate?.websocketClient(self, didUpdate: state)
        }
    }

    override init() {
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = stateQueue
        self.delegateOperationQueue = operationQueue
        super.init()
    }

    func configure(backendURLString: String, authToken: String) throws {
        guard let backendURL = URL(string: backendURLString),
              let host = backendURL.host, !host.isEmpty,
              backendURL.user == nil, backendURL.password == nil,
              backendURL.fragment == nil,
              backendURL.scheme == "wss" ||
                (backendURL.scheme == "ws" && ["localhost", "127.0.0.1", "[::1]"].contains(backendURL.host ?? "")) else {
            throw RealtimeWebSocketClientError.invalidURL
        }
        stateQueue.async { [weak self] in
            guard let self else { return }
            let didChangeConfiguration = self.backendURL != backendURL || self.authToken != authToken
            self.backendURL = backendURL
            self.authToken = authToken
            if didChangeConfiguration {
                self.suppressReconnectUntilReconfigure = false
            }
        }
    }

    func connectIfNeeded() {
        stateQueue.async { [weak self] in
            self?.connectIfNeededOnQueue()
        }
    }

    private func connectIfNeededOnQueue() {
        guard task == nil else { return }
        guard !suppressReconnectUntilReconfigure else {
            state = .disconnected
            return
        }
        guard let backendURL else {
            delegate?.websocketClient(self, didFail: RealtimeWebSocketClientError.invalidURL)
            return
        }

        shouldMaintainConnection = true
        if reconnectAttempts == 0 {
            state = .connecting
        } else if reconnectAttempts == 1 {
            state = .sleeping
        } else {
            state = .reconnecting(reconnectAttempts)
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateOperationQueue)
        urlSession = session

        var request = URLRequest(url: backendURL)
        if !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        lastCloseCode = nil
        lastCloseReason = nil
        let websocketTask = session.webSocketTask(with: request)
        task = websocketTask
        lastInboundAt = Date().timeIntervalSince1970
        hasObservedInboundOnConnection = false
        websocketTask.resume()
        schedulePing()
        receiveNextMessage(on: websocketTask)
    }

    func disconnect() {
        stateQueue.async { [weak self] in
            self?.disconnectOnQueue()
        }
    }

    private func disconnectOnQueue() {
        shouldMaintainConnection = false
        stopPing()
        cancelLegacySessionStartAcknowledgementFallback()

        tearDownConnection(closeCode: .normalClosure)
        currentConnectionID = nil
        state = .disconnected
    }

    /// The one way a socket is retired. Cancels the task first, then lets the session
    /// finish and invalidate on its own. `invalidateAndCancel()` from inside a send/receive
    /// completion — while audio frames are still queued on the task — crashed inside
    /// CFNetwork's sendMessage block (EXC_BAD_ACCESS on a null pointer).
    private func tearDownConnection(closeCode: URLSessionWebSocketTask.CloseCode) {
        if let task, task.state == .running || task.state == .suspended {
            task.cancel(with: closeCode, reason: nil)
        }
        task = nil
        // URLSession retains its delegate until invalidated (H-9); finishing (not
        // cancelling) lets in-flight sends complete with an error instead of tearing
        // down their internals underneath them.
        urlSession?.finishTasksAndInvalidate()
        urlSession = nil
    }

    func markStreamingSessionCompleted() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.pendingMessages.removeAll(keepingCapacity: true)
            self.pendingStreamingMessagesAwaitingSessionStartAcknowledgement.removeAll(keepingCapacity: true)
            self.streamingSessionState = .idle
            self.dropStreamingMessagesUntilNextSessionStart = false
            self.isAwaitingSessionStartAcknowledgement = false
            self.currentClientSessionID = nil
            self.cancelLegacySessionStartAcknowledgementFallback()
        }
    }

    func prepareForSessionRecovery() {
        stateQueue.async { [weak self] in
            self?.prepareForSessionRecoveryOnQueue()
        }
    }

    private func prepareForSessionRecoveryOnQueue() {
        pendingMessages.removeAll(keepingCapacity: true)
        pendingStreamingMessagesAwaitingSessionStartAcknowledgement.removeAll(keepingCapacity: true)
        streamingSessionState = .idle
        dropStreamingMessagesUntilNextSessionStart = true
        isAwaitingSessionStartAcknowledgement = false
        cancelLegacySessionStartAcknowledgementFallback()
    }

    func latestDiagnosticSnapshot() -> RealtimeWebSocketDebugSnapshot {
        stateQueue.sync {
            lastFailureDebugSnapshot ?? debugSnapshot()
        }
    }

    func send(_ message: ClientMessage) {
        stateQueue.async { [weak self] in
            self?.sendOnQueue(message)
        }
    }

    private func sendOnQueue(_ message: ClientMessage) {
        prepareForOutgoingMessage(message)
        guard !shouldDropOutgoingMessage(message) else { return }
        if shouldBufferUntilSessionStartAcknowledgement(message) {
            pendingStreamingMessagesAwaitingSessionStartAcknowledgement.append(message)
            return
        }
        transmitOrQueue(message)
    }

    private func transmitOrQueue(_ message: ClientMessage) {
        guard let task else {
            pendingMessages.append(message)
            connectIfNeededOnQueue()
            return
        }
        transmit(message, over: task)
    }

    private func transmit(_ message: ClientMessage, over task: URLSessionWebSocketTask) {
        // A cancelled/completed task must never receive more frames: route through the
        // normal failure path (queue + reconnect) instead.
        guard task.state == .running else {
            handleTransportFailure(RealtimeWebSocketClientError.activeSessionInterrupted, failedMessage: message)
            return
        }
        do {
            let data = try jsonEncoder.encode(message)
            guard let text = String(data: data, encoding: .utf8) else {
                throw RealtimeWebSocketClientError.encodeFailed
            }
            if message.type == .sessionStart {
                scheduleLegacySessionStartAcknowledgementFallback(for: message.clientSessionID)
            }
            task.send(.string(text)) { [weak self] error in
                // Completion handler is delivered on the delegate (state) queue.
                guard let self, let error else { return }
                guard task === self.task else { return }
                self.handleTransportFailure(error, failedMessage: message)
            }
        } catch {
            delegate?.websocketClient(self, didFail: error)
        }
    }

    private func receiveNextMessage(on receivingTask: URLSessionWebSocketTask) {
        receivingTask.receive { [weak self] result in
            // Completion handler is delivered on the delegate (state) queue.
            guard let self else { return }
            guard receivingTask === self.task else { return }

            switch result {
            case .success(let incoming):
                self.reconnectAttempts = 0
                self.lastInboundAt = Date().timeIntervalSince1970
                self.hasObservedInboundOnConnection = true
                self.state = .connected
                self.flushPendingMessages()
                self.handleIncoming(incoming)
                self.receiveNextMessage(on: receivingTask)

            case .failure(let error):
                self.handleTransportFailure(error)
            }
        }
    }

    private func handleIncoming(_ incoming: URLSessionWebSocketTask.Message) {
        switch incoming {
        case .string(let text):
            guard let data = text.data(using: .utf8) else { return }
            decodeAndEmit(data)
        case .data(let data):
            decodeAndEmit(data)
        @unknown default:
            break
        }
    }

    private func decodeAndEmit(_ data: Data) {
        do {
            let message = try jsonDecoder.decode(ServerMessage.self, from: data)
            ingestConnectionMetadata(from: message)
            delegate?.websocketClient(self, didReceive: message)
        } catch {
            delegate?.websocketClient(self, didFail: error)
        }
    }

    private func prepareForOutgoingMessage(_ message: ClientMessage) {
        switch message.type {
        case .sessionStart:
            pendingMessages.removeAll(keepingCapacity: true)
            pendingStreamingMessagesAwaitingSessionStartAcknowledgement.removeAll(keepingCapacity: true)
            streamingSessionState = .live
            dropStreamingMessagesUntilNextSessionStart = false
            isAwaitingSessionStartAcknowledgement = true
            currentClientSessionID = message.clientSessionID
            lastFailureDebugSnapshot = nil
            cancelLegacySessionStartAcknowledgementFallback()
        case .sessionEnd:
            if streamingSessionState == .live {
                streamingSessionState = .finalizing
            }
        case .audioChunk, .ping:
            break
        }
    }

    private func shouldBufferUntilSessionStartAcknowledgement(_ message: ClientMessage) -> Bool {
        realtimeOutgoingMessageDisposition(
            for: message.type,
            awaitingSessionStartAcknowledgement: isAwaitingSessionStartAcknowledgement,
            dropStreamingMessagesUntilNextSessionStart: dropStreamingMessagesUntilNextSessionStart
        ) == .bufferUntilSessionStartAcknowledgement
    }

    private func shouldDropOutgoingMessage(_ message: ClientMessage) -> Bool {
        realtimeOutgoingMessageDisposition(
            for: message.type,
            awaitingSessionStartAcknowledgement: isAwaitingSessionStartAcknowledgement,
            dropStreamingMessagesUntilNextSessionStart: dropStreamingMessagesUntilNextSessionStart
        ) == .drop
    }

    private func handleTransportFailure(_ error: Error, failedMessage: ClientMessage? = nil) {
        if streamingSessionState.isActive {
            handleInterruptedStreamingSession(with: error)
            return
        }

        delegate?.websocketClient(self, didFail: error)
        if let failedMessage, failedMessage.type != .ping {
            pendingMessages.append(failedMessage)
        }
        stopPing()
        tearDownConnection(closeCode: .goingAway)
        scheduleReconnectIfNeeded()
    }

    private func handleInterruptedStreamingSession(with error: Error) {
        lastFailureDebugSnapshot = debugSnapshot()
        print(
            "[dictation] websocket active-session interruption " +
            "connection_id=\(currentConnectionID ?? "nil") " +
            "client_session_id=\(currentClientSessionID ?? "nil") " +
            "awaiting_ack=\(isAwaitingSessionStartAcknowledgement) " +
            "pending_transport=\(pendingMessages.count) " +
            "pending_streaming=\(pendingStreamingMessagesAwaitingSessionStartAcknowledgement.count) " +
            "close_code=\(lastCloseCode.map { String($0.rawValue) } ?? "nil") " +
            "close_reason=\(lastCloseReason ?? "nil") " +
            "error=\(error.localizedDescription)"
        )
        prepareForSessionRecoveryOnQueue()
        stopPing()
        tearDownConnection(closeCode: .goingAway)
        currentClientSessionID = nil
        currentConnectionID = nil
        state = .disconnected
        delegate?.websocketClient(self, didFail: error)
    }

    private func scheduleReconnectIfNeeded() {
        guard shouldMaintainConnection else {
            state = .disconnected
            return
        }
        guard !suppressReconnectUntilReconfigure else {
            state = .disconnected
            return
        }

        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 8.0)
        state = reconnectAttempts == 1 ? .sleeping : .reconnecting(reconnectAttempts)

        stateQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connectIfNeededOnQueue()
        }
    }

    private func schedulePing() {
        stopPing()
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in
            self?.handlePingTick()
        }
        pingTimer = timer
        timer.resume()
    }

    private func stopPing() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func handlePingTick() {
        // Recycle a half-open connection: if no frame has arrived for >2 intervals the
        // socket is dead even though the OS hasn't surfaced an error yet (H-7). Only enforce
        // once the server has proven it responds on this connection, so we don't loop-recycle a
        // healthy idle connection against a backend that doesn't echo idle pings.
        if task != nil,
           hasObservedInboundOnConnection,
           RealtimeLivenessPolicy.shouldRecycle(
               now: Date().timeIntervalSince1970,
               lastInboundAt: lastInboundAt,
               pingInterval: pingInterval
           ) {
            print("[dictation] websocket liveness timeout; recycling connection")
            handleTransportFailure(RealtimeWebSocketClientError.activeSessionInterrupted)
            return
        }
        sendOnQueue(.ping())
    }

    private func flushPendingMessages() {
        guard state == .connected else { return }
        let queued = pendingMessages
        pendingMessages.removeAll(keepingCapacity: true)
        queued.forEach(transmitOrQueue(_:))
    }

    private func flushPendingStreamingMessagesAwaitingSessionStartAcknowledgement() {
        let queued = pendingStreamingMessagesAwaitingSessionStartAcknowledgement
        pendingStreamingMessagesAwaitingSessionStartAcknowledgement.removeAll(keepingCapacity: true)
        queued.forEach(transmitOrQueue(_:))
    }

    private func ingestConnectionMetadata(from message: ServerMessage) {
        if let connectionID = message.connectionID {
            currentConnectionID = connectionID
        }
        if message.type == .sessionStarted {
            handleSessionStartAcknowledgement(message)
        }
    }

    private func handleSessionStartAcknowledgement(_ message: ServerMessage) {
        guard let acknowledgedClientSessionID = message.clientSessionID else { return }
        guard acknowledgedClientSessionID == currentClientSessionID else { return }
        acknowledgeStreamingSessionStart()
    }

    private func acknowledgeStreamingSessionStart() {
        guard isAwaitingSessionStartAcknowledgement else { return }
        isAwaitingSessionStartAcknowledgement = false
        cancelLegacySessionStartAcknowledgementFallback()
        flushPendingStreamingMessagesAwaitingSessionStartAcknowledgement()
    }

    private func scheduleLegacySessionStartAcknowledgementFallback(for clientSessionID: String?) {
        cancelLegacySessionStartAcknowledgementFallback()
        guard let clientSessionID else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isAwaitingSessionStartAcknowledgement else { return }
            guard self.currentClientSessionID == clientSessionID else { return }
            print(
                "[dictation] websocket using legacy session-start compatibility " +
                "client_session_id=\(clientSessionID) pending_streaming=\(self.pendingStreamingMessagesAwaitingSessionStartAcknowledgement.count)"
            )
            self.acknowledgeStreamingSessionStart()
        }
        pendingLegacySessionStartAcknowledgementWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + sessionStartAcknowledgementFallbackDelay, execute: workItem)
    }

    private func cancelLegacySessionStartAcknowledgementFallback() {
        pendingLegacySessionStartAcknowledgementWorkItem?.cancel()
        pendingLegacySessionStartAcknowledgementWorkItem = nil
    }

    private func debugSnapshot() -> RealtimeWebSocketDebugSnapshot {
        RealtimeWebSocketDebugSnapshot(
            connectionState: state.debugDescription,
            streamingSessionState: streamingSessionState.debugDescription,
            currentClientSessionID: currentClientSessionID,
            currentConnectionID: currentConnectionID,
            awaitingSessionStartAcknowledgement: isAwaitingSessionStartAcknowledgement,
            pendingTransportMessageCount: pendingMessages.count,
            pendingStreamingMessageCount: pendingStreamingMessagesAwaitingSessionStartAcknowledgement.count,
            dropStreamingMessagesUntilNextSessionStart: dropStreamingMessagesUntilNextSessionStart,
            lastCloseCode: lastCloseCode?.rawValue,
            lastCloseReason: lastCloseReason
        )
    }
}

extension RealtimeWebSocketClient: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // Delivered on stateQueue. Ignore callbacks from a superseded task (H-8).
        guard webSocketTask === task else { return }
        reconnectAttempts = 0
        lastInboundAt = Date().timeIntervalSince1970
        state = .connected
        flushPendingMessages()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        // Delivered on stateQueue. Ignore callbacks from a superseded task (H-8).
        guard webSocketTask === task else { return }
        lastCloseCode = closeCode
        lastCloseReason = decodeCloseReason(reason)
        stopPing()
        tearDownConnection(closeCode: .normalClosure)
        if closeCode == .policyViolation {
            suppressReconnectUntilReconfigure = true
            shouldMaintainConnection = false
            state = .disconnected
            // Ask the delegate to force-refresh the auth token; reconfiguration with a fresh
            // token lifts suppressReconnectUntilReconfigure via configure() (H-14).
            delegate?.websocketClientDidRejectAuthorization(self)
            return
        }
        if streamingSessionState.isActive {
            handleInterruptedStreamingSession(with: RealtimeWebSocketClientError.activeSessionInterrupted)
            return
        }
        scheduleReconnectIfNeeded()
    }

    private func decodeCloseReason(_ reason: Data?) -> String? {
        guard let reason, !reason.isEmpty else { return nil }
        if let utf8 = String(data: reason, encoding: .utf8), !utf8.isEmpty {
            return utf8
        }
        return reason.base64EncodedString()
    }
}

private extension RealtimeConnectionState {
    var debugDescription: String {
        switch self {
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .sleeping:
            return "sleeping"
        case .connected:
            return "connected"
        case .reconnecting(let attempts):
            return "reconnecting(\(attempts))"
        }
    }
}
