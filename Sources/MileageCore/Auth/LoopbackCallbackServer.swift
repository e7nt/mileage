import Foundation
import Network

/// A single-shot HTTP listener for an OAuth redirect back to `http://localhost:<port>/<path>`.
///
/// Bound to 127.0.0.1 explicitly so the callback is never reachable from the local network
/// while a sign-in is in progress.
public final class LoopbackCallbackServer: @unchecked Sendable {
    private let port: NWEndpoint.Port
    private let expectedPath: String
    private let queue = DispatchQueue(label: "com.e7nt.mileage.oauth-callback")

    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var isFinished = false

    public init(port: UInt16, path: String) throws {
        guard let resolved = NWEndpoint.Port(rawValue: port) else {
            throw OAuthError.portUnavailable(port)
        }
        self.port = resolved
        expectedPath = path
    }

    /// Starts listening and resolves with the callback's query parameters.
    public func waitForCallback(timeout: TimeInterval = 300) async throws -> [String: String] {
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(OAuthError.timedOut))
        }
        defer {
            deadline.cancel()
            stop()
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            start()
        }
    }

    public func cancel() {
        finish(.failure(OAuthError.cancelled))
    }

    // MARK: - Listening

    private func start() {
        let parameters = NWParameters.tcp
        // A cancelled sign-in leaves the port in TIME_WAIT; without reuse the immediate retry
        // users actually attempt would fail with "port busy" for about a minute.
        parameters.allowLocalEndpointReuse = true
        // Load-bearing: NWListener binds every interface by default, so without this the
        // callback server would accept connections from the local network for the duration
        // of a sign-in.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)

        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed = state {
                    finish(.failure(OAuthError.portUnavailable(port.rawValue)))
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)

            lock.lock()
            self.listener = listener
            lock.unlock()
        } catch {
            finish(.failure(OAuthError.portUnavailable(port.rawValue)))
        }
    }

    private func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        lock.unlock()
        listener?.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil else {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data { accumulated.append(data) }

            guard let text = String(data: accumulated, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // Wait for the full request head before parsing; the query string can be long.
            guard text.contains("\r\n\r\n") else {
                if isComplete {
                    connection.cancel()
                } else {
                    receive(on: connection, buffer: accumulated)
                }
                return
            }

            let items = parseQuery(requestHead: text)
            respond(on: connection, success: items?["code"] != nil)

            if let items {
                finish(.success(items))
            }
        }
    }

    /// Pulls the query parameters out of the request line: `GET /auth/callback?code=… HTTP/1.1`.
    private func parseQuery(requestHead: String) -> [String: String]? {
        guard let requestLine = requestHead.split(separator: "\r\n").first else { return nil }
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else { return nil }

        let target = String(fields[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(target)"),
              components.path == expectedPath
        else { return nil }

        return components.queryItems?.reduce(into: [String: String]()) { result, item in
            result[item.name] = item.value
        }
    }

    private func respond(on connection: NWConnection, success: Bool) {
        let message = success
            ? "<h1>Signed in</h1><p>You can close this tab and go back to mileage.</p>"
            : "<h1>Sign-in failed</h1><p>Go back to mileage and try again.</p>"
        let html = """
        <!doctype html><meta charset="utf-8"><title>mileage</title>
        <body style="font-family:-apple-system,system-ui,sans-serif;text-align:center;padding:4rem">
        \(message)</body>
        """
        let body = Data(html.utf8)
        let head = """
        HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """

        connection.send(
            content: Data(head.utf8) + body,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    // MARK: - Completion

    /// Resolves the continuation exactly once, whichever of success, timeout, cancellation or
    /// bind failure gets there first.
    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return
        }
        isFinished = true
        self.continuation = nil
        lock.unlock()

        continuation.resume(with: result)
    }
}
