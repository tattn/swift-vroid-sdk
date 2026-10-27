#if os(macOS)
import Foundation
import Network
import Testing
@testable import VRoidSDK
@testable import VRoidSDKCore

@Suite(.serialized)
struct LoopbackCallbackServerTests {
    @Test
    func assignsAPortAndReceivesTheCallback() async throws {
        let configuredURI = URL(string: "http://127.0.0.1/oauth/callback")!
        let server = try LoopbackCallbackServer(redirectURI: configuredURI)
        let effectiveURI = try await server.start()
        defer { server.stop() }

        let port = try #require(effectiveURI.port)
        #expect(port > 0)
        #expect(port != 80)
        var callback = URLComponents(url: effectiveURI, resolvingAgainstBaseURL: false)!
        callback.queryItems = [
            URLQueryItem(name: "code", value: "code"),
            URLQueryItem(name: "state", value: "state"),
        ]

        let (body, response) = try await URLSession.shared.data(from: try #require(callback.url))
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        #expect(String(data: body, encoding: .utf8)?.contains("Authentication complete") == true)

        let received = try await server.waitForCallback()
        #expect(received.path == "/oauth/callback")
        #expect(URLComponents(url: received, resolvingAgainstBaseURL: false)?.queryItems?.count == 2)
    }

    @Test
    func receivesARequestLineSplitAcrossTCPReads() async throws {
        let server = try LoopbackCallbackServer(
            redirectURI: URL(string: "http://127.0.0.1/oauth/callback")!
        )
        let effectiveURI = try await server.start()
        defer { server.stop() }
        let port = try #require(effectiveURI.port.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) })
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        defer { connection.cancel() }
        try await Self.start(connection)

        try await Self.send(Data("GET /oauth/".utf8), on: connection)
        try await Task.sleep(for: .milliseconds(50))
        try await Self.send(
            Data("callback?code=code&state=state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8),
            on: connection
        )

        let received = try await server.waitForCallback()
        #expect(received.path == "/oauth/callback")
        #expect(URLComponents(url: received, resolvingAgainstBaseURL: false)?.queryItems?.count == 2)
    }

    private static func start(_ connection: NWConnection) async throws {
        let states = AsyncStream.makeStream(of: NWConnection.State.self)
        connection.stateUpdateHandler = { states.continuation.yield($0) }
        connection.start(queue: .global(qos: .userInitiated))
        defer { states.continuation.finish() }
        for await state in states.stream {
            switch state {
            case .ready:
                return
            case .failed(let error):
                throw error
            case .cancelled:
                throw CancellationError()
            default:
                continue
            }
        }
        throw CancellationError()
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
#endif
