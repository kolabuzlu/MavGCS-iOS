import Foundation

/// Why a link would not open, or stopped.
public struct LinkFailure: Error, Sendable, Equatable {
    /// The errno behind it, or 0 when there was none.
    public let code: Int32
    /// The short version, for a panel four lines tall shared with the
    /// vehicle's own messages. The system's own text runs to a full line of
    /// port numbers around the one word that matters.
    public let reason: String
    /// Whether it happened while opening, rather than on a link that was up.
    public let opening: Bool

    static func errno(_ code: Int32, opening: Bool, port: UInt16 = 0) -> LinkFailure {
        let reason: String
        switch code {
        case ECONNREFUSED: reason = "nothing is listening there"
        case EHOSTUNREACH, ENETUNREACH: reason = "no route to that address"
        case ETIMEDOUT: reason = "timed out"
        case EACCES, EPERM: reason = "permission denied"
        case EADDRINUSE: reason = "port \(port) is already in use"
        case EADDRNOTAVAIL: reason = "that address is not on this device"
        case ENETDOWN: reason = "the network is down"
        default: reason = String(cString: strerror(code)).lowercased()
        }
        return LinkFailure(code: code, reason: reason, opening: opening)
    }

    static let closedByPeer = LinkFailure(code: 0, reason: "closed at the other end", opening: false)
    static let notFound = LinkFailure(code: 0, reason: "could not find that address", opening: true)
    static let timedOut = LinkFailure(code: ETIMEDOUT, reason: "timed out", opening: true)

    /// A refusal that on iOS usually means Local Network access is off,
    /// which from the app's side looks exactly like a missing route.
    public var mayBeLocalNetworkPermission: Bool {
        code == EHOSTUNREACH || code == ENETUNREACH || code == EPERM
    }
}

enum SendResult: Equatable {
    case sent
    /// A listening UDP link before anything has spoken: nowhere to send.
    case noPeer
    case failed(LinkFailure)
}

/// A byte pipe to the vehicle.
protocol Transport: AnyObject, Sendable {
    /// Open and start reading. Both callbacks arrive on the transport's own
    /// thread; [onEnd] is not called for a link closed by stop().
    func start(onBytes: @escaping @Sendable ([UInt8]) -> Void, onEnd: @escaping @Sendable (LinkFailure) -> Void)
    func send(_ bytes: [UInt8]) -> SendResult
    func stop()
}

/// UDP and TCP over plain sockets, one reading thread per link.
///
/// The reading thread owns the socket: it opens it, reads it, and is the
/// only thing that ever closes it. stop() just says so and waits for the
/// next read timeout to be noticed. Closing from outside would race the
/// read, and a descriptor number freed under a blocked read can be handed
/// to the very next socket opened -- a reconnect -- which the stale thread
/// would then carry on reading.
final class SocketTransport: Transport, @unchecked Sendable {
    /// How often a blocked read wakes to see whether it should stop.
    private static let readTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
    private static let sendTimeout = timeval(tv_sec: 1, tv_usec: 0)
    private static let connectTimeoutMs: Int32 = 5000

    private let config: LinkConfig
    private let lock = NSLock()
    // Guarded by lock.
    private var fd: Int32 = -1
    private var stopped = false
    private var peer: sockaddr_in?

    init(config: LinkConfig) {
        self.config = config
    }

    func start(onBytes: @escaping @Sendable ([UInt8]) -> Void, onEnd: @escaping @Sendable (LinkFailure) -> Void) {
        let thread = Thread { [self] in
            run(onBytes: onBytes, onEnd: onEnd)
        }
        thread.name = "mavlink-rx"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        // A TCP read wakes at once on shutdown; a UDP one at its timeout.
        if fd >= 0 && config.type == .tcp {
            shutdown(fd, SHUT_RDWR)
        }
        lock.unlock()
    }

    func send(_ bytes: [UInt8]) -> SendResult {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, fd >= 0 else { return .noPeer }
        switch config.type {
        case .udp:
            // In LISTEN mode there is no peer until something speaks first.
            guard var destination = peer else { return .noPeer }
            let sent = bytes.withUnsafeBytes { buffer in
                withUnsafePointer(to: &destination) { address in
                    address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            return sent < 0 ? .failed(.errno(Darwin.errno, opening: false)) : .sent
        case .tcp:
            var offset = 0
            while offset < bytes.count {
                let sent = bytes.withUnsafeBytes { buffer in
                    Darwin.send(fd, buffer.baseAddress! + offset, buffer.count - offset, 0)
                }
                if sent < 0 {
                    if Darwin.errno == EINTR { continue }
                    return .failed(.errno(Darwin.errno, opening: false))
                }
                offset += sent
            }
            return .sent
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run(onBytes: @Sendable ([UInt8]) -> Void, onEnd: @Sendable (LinkFailure) -> Void) {
        let socket: Int32
        do {
            socket = try config.type == .udp ? openUdp() : openTcp()
        } catch {
            if !isStopped { onEnd(error as? LinkFailure ?? .notFound) }
            return
        }
        lock.lock()
        let cancelled = stopped
        if !cancelled { fd = socket }
        lock.unlock()
        if cancelled {
            close(socket)
            return
        }

        let failure = readLoop(socket, onBytes: onBytes)

        lock.lock()
        fd = -1
        let wasStopped = stopped
        lock.unlock()
        close(socket)
        if !wasStopped, let failure {
            onEnd(failure)
        }
    }

    /// Read until stopped or broken; the failure, or nil if stopped.
    private func readLoop(_ socket: Int32, onBytes: @Sendable ([UInt8]) -> Void) -> LinkFailure? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isStopped {
            let count: Int
            if config.type == .udp {
                var from = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                count = withUnsafeMutablePointer(to: &from) { address in
                    address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socket, &buffer, buffer.count, 0, $0, &length)
                    }
                }
                if count > 0 && config.udpMode == .listen {
                    // Whoever just spoke is who to answer. When dialling out
                    // the peer is the one that was asked for, whatever port
                    // it happens to reply from.
                    lock.lock()
                    peer = from
                    lock.unlock()
                }
            } else {
                count = recv(socket, &buffer, buffer.count, 0)
                if count == 0 { return .closedByPeer }
            }
            if count > 0 {
                onBytes(Array(buffer[0..<count]))
            } else {
                let code = Darwin.errno
                if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { continue }
                // A peer that closes with our frames still unread in its
                // buffer -- a simulator that quits, say -- resets rather
                // than closes. To the pilot it is the same event.
                if code == ECONNRESET && config.type == .tcp { return .closedByPeer }
                return isStopped ? nil : .errno(code, opening: false)
            }
        }
        return nil
    }

    private func openUdp() throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { throw LinkFailure.errno(Darwin.errno, opening: true) }
        // Both, so a reconnect can bind the port straight away while the
        // previous link's thread is still noticing that it has been stopped.
        setOption(socket, SOL_SOCKET, SO_REUSEADDR, 1)
        setOption(socket, SOL_SOCKET, SO_REUSEPORT, 1)
        setOption(socket, SOL_SOCKET, SO_NOSIGPIPE, 1)
        setTime(socket, SO_RCVTIMEO, Self.readTimeout)

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr = in_addr(s_addr: INADDR_ANY)
        // Listening binds the port the vehicle streams to. Dialling out, the
        // local port does not matter, but the socket still has to be bound
        // to be read from, and the peer is known up front -- which is what
        // lets the heartbeat go out at once. A WiFi bridge stays silent, or
        // broadcasts, until it has heard from us.
        local.sin_port = config.udpMode == .listen ? config.port.bigEndian : 0
        let bound = withUnsafePointer(to: &local) { address in
            address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            let code = Darwin.errno
            close(socket)
            throw LinkFailure.errno(code, opening: true, port: config.port)
        }
        if config.udpMode == .connect {
            do {
                let address = try resolve(config.host, port: config.port, type: SOCK_DGRAM)
                lock.lock()
                peer = address
                lock.unlock()
            } catch {
                close(socket)
                throw error
            }
        }
        return socket
    }

    private func openTcp() throws -> Int32 {
        var address = try resolve(config.host, port: config.port, type: SOCK_STREAM)
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socket >= 0 else { throw LinkFailure.errno(Darwin.errno, opening: true) }
        setOption(socket, SOL_SOCKET, SO_NOSIGPIPE, 1)
        setOption(socket, IPPROTO_TCP, TCP_NODELAY, 1)

        // Connected without blocking so the attempt can be given up on: a
        // blocking connect to an address with nothing behind it waits for
        // the system's own timeout, well over a minute.
        let flags = fcntl(socket, F_GETFL, 0)
        _ = fcntl(socket, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            let code = Darwin.errno
            guard code == EINPROGRESS else {
                close(socket)
                throw LinkFailure.errno(code, opening: true)
            }
            var poller = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&poller, 1, Self.connectTimeoutMs)
            if ready <= 0 {
                close(socket)
                throw LinkFailure.timedOut
            }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &length)
            if error != 0 {
                close(socket)
                throw LinkFailure.errno(error, opening: true)
            }
        }
        _ = fcntl(socket, F_SETFL, flags & ~O_NONBLOCK)
        setTime(socket, SO_RCVTIMEO, Self.readTimeout)
        setTime(socket, SO_SNDTIMEO, Self.sendTimeout)
        return socket
    }

    private func resolve(_ host: String, port: UInt16, type: Int32) throws -> sockaddr_in {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = type
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host.trimmingCharacters(in: .whitespaces), nil, &hints, &list) == 0,
              let first = list, let found = first.pointee.ai_addr
        else {
            throw LinkFailure.notFound
        }
        defer { freeaddrinfo(list) }
        var address = found.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        address.sin_port = port.bigEndian
        return address
    }

    private func setOption(_ socket: Int32, _ level: Int32, _ name: Int32, _ value: Int32) {
        var value = value
        setsockopt(socket, level, name, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    private func setTime(_ socket: Int32, _ name: Int32, _ value: timeval) {
        var value = value
        setsockopt(socket, SOL_SOCKET, name, &value, socklen_t(MemoryLayout<timeval>.size))
    }
}
