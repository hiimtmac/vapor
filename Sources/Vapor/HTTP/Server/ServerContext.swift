public import NIOHTTPServer

/// Everything the HTTP server needs from the application
///
/// The `FreezableType`s here are references to the same types the application holds so any changes are passed through
///
/// A custom ``Server`` created with ``Application/ServerOption/factory(_:)`` receives the context, and serves the
/// application through ``makeHTTPServerHandler()``.
public final class ServerContext: Sendable {
    let configuration: FreezableType<ServerConfiguration>
    let routes: FreezableType<RouteStorage>
    let middlewares: FreezableType<Middlewares>
    let responder: Application.ServiceOptionType<any Responder>

    package let contentConfiguration: ContentConfiguration

    init(
        configuration: FreezableType<ServerConfiguration>,
        routes: FreezableType<RouteStorage>,
        middlewares: FreezableType<Middlewares>,
        responder: Application.ServiceOptionType<any Responder>,
        contentConfiguration: ContentConfiguration
    ) {
        self.configuration = configuration
        self.routes = routes
        self.middlewares = middlewares
        self.responder = responder
        self.contentConfiguration = contentConfiguration
    }

    /// The default max body size for routes that do not set one of their own.
    var defaultMaxBodySize: ByteCount {
        self.routes.value.defaultMaxBodySize
    }

    /// Makes a swift-http-server request handler that serves the application's routes and middleware.
    ///
    /// Call this when the server starts serving rather than when it's created: the handler captures the responder
    /// chain, which is complete once the application has started and frozen its routes and middleware. Pass the
    /// handler to `NIOHTTPServer`, for example to `serve(acceptedChannel:handler:)` for connections the server accepts
    /// itself. The handler applies the application's ``ServerConfiguration`` request limits; binding, TLS and HTTP
    /// version settings are left to the server that runs it.
    public func makeHTTPServerHandler() -> some HTTPServerRequestHandler<
        NIOHTTPServer.RequestContext, NIOHTTPServer.Reader, NIOHTTPServer.ResponseSender
    > {
        VaporHTTPServerHandler(context: self, responder: self.makeResponder())
    }

    /// Builds the responder chain.
    package func makeResponder() -> any Responder {
        switch self.responder {
        case .default:
            DefaultResponder(
                routes: self.routes.value,
                middleware: self.middlewares.value.resolve()
            )
        case .provided(let provided):
            provided
        }
    }
}
