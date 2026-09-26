import Foundation
import Testing
@testable import MavlinkCore

/// The real transport over loopback, against a vehicle made of raw sockets:
/// the three shapes a link comes in, and the two ways one ends.
struct SocketTests {
    @Test func udpListenLearnsWhoToAnswerFromWhoSpoke() throws {
        let port = try freePort(type: SOCK_DGRAM)
        let client = liveClient()
        client.connect(LinkConfig(type: .udp, host: "0.0.0.0", port: port, udpMode: .listen))
        defer { client.disconnect() }

        let vehicle = try RawSocket(type: SOCK_DGRAM)
        var encoder = FrameEncoder(systemId: 1, componentId: 1)
        #expect(waitUntil(2) {
            // Resent until the client's socket is bound and hears it.
            vehicle.send(encoder.encode(planeHeartbeat()), toPort: port)
            return client.snapshot().heard
        })
        // Stream setup goes out the moment the vehicle is heard, to whoever
        // it was heard from.
        let reply = vehicle.receive(timeout: 3)
        #expect(!reply.isEmpty)
        var parser = FrameParser()
        #expect(parser.push(reply).contains { $0.frame.systemId == MavlinkClient.gcsSystemId })
    }

    @Test func udpConnectSpeaksFirst() throws {
        // What the mLRS bridge needs: it broadcasts until something speaks
        // to it, and iOS will not hand an app a broadcast.
        let vehicle = try RawSocket(type: SOCK_DGRAM, bind: true)
        let client = liveClient()
        client.connect(LinkConfig(type: .udp, host: "127.0.0.1", port: vehicle.port, udpMode: .connect))
        defer { client.disconnect() }

        let (bytes, from) = vehicle.receiveFrom(timeout: 3)
        var parser = FrameParser()
        let heartbeat = parser.push(bytes).compactMap { $0.message as? Heartbeat }.first
        #expect(heartbeat?.type == MavType.gcs)

        var encoder = FrameEncoder(systemId: 1, componentId: 1)
        #expect(waitUntil(2) {
            vehicle.send(encoder.encode(planeHeartbeat()), to: from)
            return client.snapshot().heard
        })
    }

    @Test func tcpCarriesTelemetryAndSaysWhenTheOtherEndHangsUp() throws {
        let server = try RawSocket(type: SOCK_STREAM, bind: true)
        #expect(listen(server.fd, 1) == 0)
        let client = liveClient()
        client.connect(LinkConfig(type: .tcp, host: "127.0.0.1", port: server.port))
        defer { client.disconnect() }

        let connection = try #require(server.accept(timeout: 3))
        var encoder = FrameEncoder(systemId: 1, componentId: 1)
        let frame = encoder.encode(planeHeartbeat())
        _ = frame.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }
        #expect(waitUntil(2) { client.snapshot().heard })

        close(connection)
        #expect(waitUntil(2) { !client.snapshot().linkOpen })
        #expect(client.snapshot().messages.last?.text == "The link closed at the other end.")
    }

    @Test func aRefusedTcpConnectionSaysSo() throws {
        let port = try freePort(type: SOCK_STREAM)
        let client = liveClient()
        client.connect(LinkConfig(type: .tcp, host: "127.0.0.1", port: port))
        #expect(waitUntil(3) { !client.snapshot().linkOpen })
        #expect(client.snapshot().messages.last?.text == "Could not reach TCP 127.0.0.1:\(port) - nothing is listening there.")
    }

    @Test func anAddressThatDoesNotExistSaysSo() throws {
        let client = liveClient()
        client.connect(LinkConfig(type: .tcp, host: "no-such-host.invalid", port: 5760))
        #expect(waitUntil(5) { !client.snapshot().linkOpen })
        #expect(client.snapshot().messages.last?.text == "Could not reach TCP no-such-host.invalid:5760 - could not find that address.")
    }
}

// MARK: - Helpers

private func liveClient() -> MavlinkClient {
    MavlinkClient(
        clock: { ProcessInfo.processInfo.systemUptime },
        transport: { SocketTransport(config: $0) },
        runsTimer: true
    )
}

private func planeHeartbeat() -> Heartbeat {
    Heartbeat(type: MavType.fixedWing, autopilot: MavAutopilot.ardupilotmega, customMode: 12, systemStatus: MavState.active)
}

private func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

/// A port nothing is using, found by asking the system for one.
private func freePort(type: Int32) throws -> UInt16 {
    let socket = try RawSocket(type: type, bind: true)
    return socket.port
}

private final class RawSocket {
    let fd: Int32
    private(set) var port: UInt16 = 0

    init(type: Int32, bind shouldBind: Bool = false) throws {
        fd = socket(AF_INET, type, type == SOCK_DGRAM ? IPPROTO_UDP : IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        if shouldBind || type == SOCK_DGRAM {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            address.sin_port = 0
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            port = UInt16(bigEndian: address.sin_port)
        }
    }

    deinit { close(fd) }

    func send(_ bytes: [UInt8], toPort port: UInt16) {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = port.bigEndian
        send(bytes, to: address)
    }

    func send(_ bytes: [UInt8], to address: sockaddr_in) {
        var address = address
        _ = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func receive(timeout: Double) -> [UInt8] {
        receiveFrom(timeout: timeout).0
    }

    func receiveFrom(timeout: Double) -> ([UInt8], sockaddr_in) {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var from = sockaddr_in()
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return ([], from) }
        var buffer = [UInt8](repeating: 0, count: 2048)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
            }
        }
        return (count > 0 ? Array(buffer[0..<count]) : [], from)
    }

    func accept(timeout: Double) -> Int32? {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return nil }
        let connection = Darwin.accept(fd, nil, nil)
        return connection >= 0 ? connection : nil
    }
}
