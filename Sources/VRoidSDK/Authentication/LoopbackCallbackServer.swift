#if os(macOS)
import Foundation
import Network
import Synchronization

/// One-time HTTP server that receives a single OAuth redirect on the
/// loopback interface and then shuts down.
final class LoopbackCallbackServer: Sendable {
    private static let maximumRequestSize = 16 * 1024
    private static let requestLineTerminator = Data("\r\n".utf8)

    /// One-shot cell: resumes an awaiting continuation exactly once,
    /// buffering the first result when it arrives before the await.
    private struct ResultCell {
        private var continuation: CheckedContinuation<URL, any Error>?
        private var result: Result<URL, any Error>?

        /// Accepts the first result and returns the continuation to resume
        /// with it, if one is already waiting. Later results are ignored.
        mutating func finish(_ newResult: Result<URL, any Error>) -> CheckedContinuation<URL, any Error>? {
            guard result == nil else { return nil }
            result = newResult
            defer { continuation = nil }
            return continuation
        }

        /// Registers a waiting continuation, or returns the buffered result
        /// to resume with immediately.
        mutating func awaitResult(_ newContinuation: CheckedContinuation<URL, any Error>) -> Result<URL, any Error>? {
            if let result { return result }
            continuation = newContinuation
            return nil
        }
    }

    private struct State {
        var listener: NWListener?
        var connections: [NWConnection] = []
        var start = ResultCell()
        var callback = ResultCell()
    }

    private let state = Mutex(State())
    private let requestedPort: NWEndpoint.Port
    private let redirectURI: URL
    private let expectedPath: String

    init(redirectURI: URL) throws {
        guard redirectURI.scheme == "http",
              let host = redirectURI.host(),
              host == "127.0.0.1" || host == "localhost"
        else {
            throw VRoidHubError.invalidConfiguration(
                "loopbackServer requires an http://127.0.0.1 redirect URI"
            )
        }
        if let port = redirectURI.port {
            guard (1...Int(UInt16.max)).contains(port),
                  let validPort = NWEndpoint.Port(rawValue: UInt16(port))
            else {
                throw VRoidHubError.invalidConfiguration("Invalid loopback port: \(port)")
            }
            requestedPort = validPort
        } else {
            requestedPort = .any
        }
        self.redirectURI = redirectURI
        self.expectedPath = redirectURI.path.isEmpty ? "/" : redirectURI.path
    }

    /// Starts listening and returns the redirect URI containing the bound port.
    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Bind to the loopback interface only; never accept remote connections.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: requestedPort
        )
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] listenerState in
            guard let self else { return }
            switch listenerState {
            case .ready:
                if let port = listener.port, let effectiveRedirectURI = self.redirectURI(port: port) {
                    self.finishStart(.success(effectiveRedirectURI))
                } else {
                    self.finishStart(.failure(VRoidHubError.authenticationFailed))
                }
            case .failed(let error):
                self.finishStart(.failure(error))
                self.finishCallback(.failure(error))
            case .cancelled:
                self.finishStart(.failure(CancellationError()))
            default:
                break
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pending: Result<URL, any Error>? = state.withLock { state in
                    state.listener = listener
                    return state.start.awaitResult(continuation)
                }
                if let pending {
                    continuation.resume(with: pending)
                } else {
                    listener.start(queue: .global(qos: .userInitiated))
                }
            }
        } onCancel: {
            stop()
        }
    }

    func waitForCallback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pending: Result<URL, any Error>? = state.withLock {
                    $0.callback.awaitResult(continuation)
                }
                if let pending {
                    continuation.resume(with: pending)
                }
            }
        } onCancel: {
            finishCallback(.failure(CancellationError()))
        }
    }

    func stop() {
        finishStart(.failure(CancellationError()))
        let (listener, connections): (NWListener?, [NWConnection]) = state.withLock { state in
            defer {
                state.listener = nil
                state.connections = []
            }
            return (state.listener, state.connections)
        }
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    private func finishStart(_ result: Result<URL, any Error>) {
        let continuation = state.withLock { $0.start.finish(result) }
        continuation?.resume(with: result)
    }

    private func finishCallback(_ result: Result<URL, any Error>) {
        let continuation = state.withLock { $0.callback.finish(result) }
        continuation?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        state.withLock { $0.connections.append(connection) }
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: connection, accumulatedData: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulatedData: Data) {
        let remainingCapacity = Self.maximumRequestSize - accumulatedData.count
        guard remainingCapacity > 0 else {
            respond(connection, status: "431 Request Header Fields Too Large", body: "Request too large")
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: remainingCapacity) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil else {
                self.respond(connection, status: "400 Bad Request", body: "Bad request")
                return
            }
            var received = accumulatedData
            if let data {
                received.append(data)
            }
            if received.range(of: Self.requestLineTerminator) != nil {
                self.processRequest(received, on: connection)
                return
            }
            guard !isComplete, received.count < Self.maximumRequestSize else {
                self.respond(connection, status: "400 Bad Request", body: "Bad request")
                return
            }
            self.receiveRequest(on: connection, accumulatedData: received)
        }
    }

    private func processRequest(_ data: Data, on connection: NWConnection) {
        // Only the path and query of the callback URL matter, so resolve
        // the request target against a fixed base.
        guard let request = String(data: data, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first,
              let target = Self.requestTarget(fromRequestLine: requestLine),
              let url = URL(string: target, relativeTo: URL(string: "http://127.0.0.1")!)
        else {
            respond(connection, status: "400 Bad Request", body: "Bad request")
            return
        }
        guard url.path == expectedPath || (url.path.isEmpty && expectedPath == "/") else {
            respond(connection, status: "404 Not Found", body: "Not found")
            return
        }
        respond(
            connection,
            status: "200 OK",
            body: "<html><body>Authentication complete. You can close this window and return to the app.</body></html>"
        )
        finishCallback(.success(url.absoluteURL))
    }

    private static func requestTarget(fromRequestLine line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    private func redirectURI(port: NWEndpoint.Port) -> URL? {
        guard var components = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.port = Int(port.rawValue)
        return components.url
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + payload, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.state.withLock { state in
                state.connections.removeAll { $0 === connection }
            }
        })
    }
}
#endif
