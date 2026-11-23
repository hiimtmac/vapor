import HTTPTypes
import NIOCore
import NIOHTTPServer
import NIOPosix
import RoutingKit
import Synchronization
import Testing
import Vapor
import VaporTesting

@Suite("Server Factory Tests")
struct ServerFactoryTests {
    @Test("A factory-made server serves the application's routes and middleware", .timeLimit(.minutes(1)))
    func factoryServerServesRoutes() async throws {
        try await withApp(services: .init(server: .factory { AcceptingServer(context: $0) })) { app in
            // Registered after the server was created: the handler is made when the server starts.
            app.routes.get("ping") { _ in "pong" }
            app.routes.post("echo") { req async throws -> String in
                try await req.body.string() ?? ""
            }
            app.middleware.use(HeaderMiddleware())

            try await app.testing(.running) { client in
                let ping = try await client.get("/ping")
                #expect(ping.status == .ok)
                #expect(ping.headers[.init("X-Test")!] == "factory")
                try #expect(await ping.body.requireString() == "pong")

                let echo = try await client.post("/echo") { req in
                    req.body = .init(string: "hello")
                }
                #expect(echo.status == .ok)
                try #expect(await echo.body.requireString() == "hello")

                let missing = try await client.get("/missing")
                #expect(missing.status == .notFound)
            }
        }
    }
}

private struct HeaderMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        var response = try await next.respond(to: request)
        response.headers[.init("X-Test")!] = "factory"
        return response
    }
}

/// A custom server that accepts TCP connections itself and serves the application through
/// ``ServerContext/makeHTTPServerHandler()``, as a server for a transport `NIOHTTPServer` doesn't bind would.
private final class AcceptingServer: Server {
    let context: ServerContext
    private let address = Mutex<Vapor.SocketAddress?>(nil)
    private let bound = Checkpoint()

    init(context: ServerContext) {
        self.context = context
    }

    func run() async throws {
        let server = NIOHTTPServer(
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )
        let handler = self.context.makeHTTPServerHandler()
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singletonMultiThreadedEventLoopGroup)
            .childChannelOption(.autoRead, value: false)
            .bind(host: "127.0.0.1", port: 0) { channel in
                channel.eventLoop.makeSucceededFuture(channel)
            }
        let port = try #require(listener.channel.localAddress?.port)
        self.address.withLock { $0 = Vapor.SocketAddress(ipAddress: "127.0.0.1", port: port) }
        self.bound.reach()

        try await listener.executeThenClose { inbound in
            try await withThrowingDiscardingTaskGroup { connections in
                for try await channel in inbound {
                    connections.addTask { try await server.serve(acceptedChannel: channel, handler: handler) }
                }
            }
        }
    }

    var listeningAddress: Vapor.SocketAddress {
        get async throws {
            await self.bound.wait()
            return try #require(self.address.withLock { $0 })
        }
    }
}
