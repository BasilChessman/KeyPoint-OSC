import Darwin
import Foundation

public struct UDPError: Error, CustomStringConvertible {
    public let description: String

    static func posix(_ what: String) -> UDPError {
        UDPError(description: "\(what): \(String(cString: strerror(errno)))")
    }
}

/// Source of a received datagram.
public struct UDPPeer: Hashable, Sendable {
    public let host: String
    public let port: UInt16
}

/// Receives UDP datagrams on a port, calling `handler` on a private queue, and can
/// reply from the same socket (so replies come from the port the client sent to).
/// BSD sockets rather than NWListener: UDP listeners in Network framework create a
/// connection per peer, which is awkward for a connectionless protocol.
public final class UDPListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "keypoint.udp.listen")
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var fd: Int32 = -1
    private var family: Int32 = AF_INET6

    public init() {}

    /// Starts listening. `localOnly` binds to 127.0.0.1 instead of all interfaces.
    public func start(port: UInt16, localOnly: Bool, handler: @escaping @Sendable (Data, UDPPeer) -> Void) throws {
        stop()
        if localOnly {
            try startIPv4Loopback(port: port, handler: handler)
            return
        }
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw UDPError.posix("socket") }
        var yes: Int32 = 1
        var no: Int32 = 0
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Dual-stack: accept IPv4 (as mapped addresses) and IPv6 on one socket.
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size))
        var rcv: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard ok == 0 else {
            let err = UDPError.posix("bind port \(port)")
            close(fd)
            throw err
        }
        attach(fd, family: AF_INET6, handler: handler)
    }

    private func startIPv4Loopback(port: UInt16, handler: @escaping @Sendable (Data, UDPPeer) -> Void) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw UDPError.posix("socket") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else {
            let err = UDPError.posix("bind 127.0.0.1:\(port)")
            close(fd)
            throw err
        }
        attach(fd, family: AF_INET, handler: handler)
    }

    private func attach(_ fd: Int32, family: Int32, handler: @escaping @Sendable (Data, UDPPeer) -> Void) {
        var size: Int32 = 65_535
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        lock.withLock {
            self.fd = fd
            self.family = family
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var storage = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &len)
                }
            }
            guard n > 0, let peer = UDPPeer(storage) else { return }
            handler(Data(buffer[0..<n]), peer)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        lock.withLock { fd = -1 }
    }

    /// Sends from the listening socket.
    public func send(_ data: Data, to host: String, port: UInt16) throws {
        let (fd, family) = lock.withLock { (self.fd, self.family) }
        guard fd >= 0 else { throw UDPError(description: "not listening") }
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = AI_NUMERICSERV | (family == AF_INET6 ? AI_V4MAPPED : 0)
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &result)
        guard rc == 0, let info = result else {
            throw UDPError(description: "resolve \(host): \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(result) }
        let sent = data.withUnsafeBytes { raw in
            sendto(fd, raw.baseAddress, data.count, 0, info.pointee.ai_addr, info.pointee.ai_addrlen)
        }
        guard sent == data.count else { throw UDPError.posix("send to \(host):\(port)") }
    }

    deinit { source?.cancel() }
}

/// Sends UDP datagrams to one or more targets. The send buffer is raised so datagrams
/// up to ~64 KB (long notes, large JSON) aren't rejected by macOS's 9 KB default.
public final class UDPSender: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [Int32: Int32] = [:] // address family -> fd

    public init() {}

    public func send(_ data: Data, to host: String, port: UInt16) throws {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        hints.ai_flags = AI_NUMERICSERV
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &result)
        guard rc == 0, let info = result else {
            throw UDPError(description: "resolve \(host): \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(result) }
        let fd = try socket(for: info.pointee.ai_family)
        let sent = data.withUnsafeBytes { raw in
            sendto(fd, raw.baseAddress, data.count, 0, info.pointee.ai_addr, info.pointee.ai_addrlen)
        }
        guard sent == data.count else { throw UDPError.posix("send to \(host):\(port)") }
    }

    private func socket(for family: Int32) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if let fd = sockets[family] { return fd }
        let fd = Darwin.socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw UDPError.posix("socket") }
        var size: Int32 = 65_535
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        sockets[family] = fd
        return fd
    }

    deinit {
        for fd in sockets.values { close(fd) }
    }
}

extension UDPPeer {
    init?(_ storage: sockaddr_storage) {
        var storage = storage
        let length = socklen_t(storage.ss_len)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var serv = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let rc = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), &serv, socklen_t(serv.count),
                            NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard rc == 0 else { return nil }
        var name = Self.string(host)
        // Report IPv4 peers on the dual-stack socket as plain IPv4.
        if name.hasPrefix("::ffff:") { name.removeFirst(7) }
        self.host = name
        self.port = UInt16(Self.string(serv)) ?? 0
    }

    private static func string(_ chars: [CChar]) -> String {
        String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
