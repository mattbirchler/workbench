import Dispatch
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// Listens for the Mac and iPhone apps' WebSocket connections and hands
/// each to the server as a `HostClient`.
///
/// It listens on this machine only by default. Tailscale Serve (or any
/// reverse proxy that speaks HTTPS) puts it on the network, as on a Mac,
/// so the pairing code never crosses a network unencrypted.
public final class WebSocketListener {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private weak var server: HostServer?

    public init(server: HostServer) {
        self.server = server
    }

    /// Starts listening. Throws if the port is taken.
    public func start(host: String, port: Int) throws {
        let server = self.server
        let upgrader = NIOWebSocketServerUpgrader(
            // A message with pictures can run to megabytes.
            maxFrameSize: 32 << 20,
            shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { channel, _ in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOWebSocketFrameAggregator(minNonFinalFragmentSize: 1, maxAccumulatedFrameCount: 4096,
                                                    maxAccumulatedFrameSize: 32 << 20),
                        ConnectionHandler(server: server),
                    ])
                }
            })
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let plain = PlainRequestHandler()
                let upgrade: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { _ in channel.pipeline.removeHandler(plain, promise: nil) })
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: upgrade).flatMap {
                    channel.pipeline.addHandler(plain)
                }
            }
            .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
        channel = try bootstrap.bind(host: host, port: port).wait()
    }

    public func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }
}

/// Answers a browser or a health check that isn't a WebSocket.
private final class PlainRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        let body = "Workbench host. Connect with the Workbench app.\n"
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: String(body.utf8.count))
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
}

/// One device's WebSocket. Frames arrive on NIO's thread and are passed to
/// the server on the main queue, where everything else lives.
private final class ConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private weak var server: HostServer?
    private var client: HostClient?
    private var closed = false

    init(server: HostServer?) {
        self.server = server
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        let client = HostClient(
            send: { data in
                // Binary, so neither end makes a string of a frame that
                // can run to megabytes.
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: buffer), promise: nil)
            },
            close: { channel.close(promise: nil) })
        self.client = client
        let server = server
        DispatchQueue.main.async { server?.connected(client) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary, .text:
            var payload = frame.unmaskedData
            guard let bytes = payload.readBytes(length: payload.readableBytes), let client else { return }
            let server = server
            DispatchQueue.main.async { server?.received(Data(bytes), from: client) }
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        case .connectionClose:
            context.close(promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        gone()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func gone() {
        guard !closed, let client else { return }
        closed = true
        let server = server
        DispatchQueue.main.async { server?.disconnected(client) }
    }
}
