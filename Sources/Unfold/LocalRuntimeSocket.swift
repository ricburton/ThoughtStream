import Foundation
import CryptoKit
import Darwin

/// Codex's Unix endpoint carries WebSocket frames, not raw JSON lines. This
/// local-only adapter keeps the existing JSON protocol independent of transport.
@MainActor
final class LocalRuntimeSocket {
    var onMessage: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?
    private var handle: FileHandle?
    private var buffer = Data()
    private var fragments = Data()

    func open(_ url: URL) async throws {
        let fd = try await Task.detached { try Self.handshake(url) }.value
        if Task.isCancelled { Darwin.close(fd); throw CancellationError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, self.handle != nil else { return }
                if data.isEmpty { self.disconnected() }
                else { self.receive(data) }
            }
        }
    }

    func send(_ data: Data) throws { try write(data, opcode: 1) }

    func close() {
        handle?.readabilityHandler = nil
        try? handle?.close(); handle = nil
    }

    private func disconnected() { close(); onDisconnect?() }

    private func write(_ payload: Data, opcode: UInt8) throws {
        guard let handle else { throw CodexConnection.error("Chat connection is closed.") }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65535 {
            frame.append(0x80 | 126)
            frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 255))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(payload.count) >> shift) & 255)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try handle.write(contentsOf: frame)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while buffer.count >= 2 {
            let bytes = [UInt8](buffer.prefix(14))
            let opcode = bytes[0] & 15, final = bytes[0] & 0x80 != 0
            var length = UInt64(bytes[1] & 127), offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return }
                length = UInt64(bytes[2]) << 8 | UInt64(bytes[3]); offset = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { return }
                length = bytes[2..<10].reduce(0) { ($0 << 8) | UInt64($1) }; offset = 10
            }
            guard length <= 64 * 1024 * 1024, bytes[1] & 0x80 == 0 else { disconnected(); return }
            guard buffer.count >= offset + Int(length) else { return }
            let start = buffer.startIndex + offset
            let payload = Data(buffer[start..<(start + Int(length))])
            buffer.removeFirst(offset + Int(length))
            switch opcode {
            case 0, 1, 2:
                fragments.append(payload)
                guard fragments.count <= 64 * 1024 * 1024 else { disconnected(); return }
                if final { let message = fragments; fragments.removeAll(keepingCapacity: true); onMessage?(message) }
            case 8: disconnected(); return
            case 9: do { try write(payload, opcode: 10) } catch { disconnected(); return }
            case 10: break
            default: disconnected(); return
            }
        }
    }

    private nonisolated static func handshake(_ url: URL) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var succeeded = false
        defer { if !succeeded { Darwin.close(fd) } }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG)) }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in path.withUnsafeBytes { bytes.copyBytes(from: $0) } }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0), noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let request = Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8)
        try request.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                sent += count
            }
        }
        // Read only headers; leave the first frame in the socket for the handler.
        var response = Data(), byte: UInt8 = 0
        while !response.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard response.count < 16384, Darwin.recv(fd, &byte, 1, 0) == 1 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT)) }
            response.append(byte)
        }
        let headers = String(decoding: response, as: UTF8.self)
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        guard headers.hasPrefix("HTTP/1.1 101 "), headers.lowercased().contains("sec-websocket-accept: " + accept.lowercased()) else {
            throw NSError(domain: "ThoughtStream", code: 1, userInfo: [NSLocalizedDescriptionKey: "The local chat connection could not be opened."])
        }
        timeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        succeeded = true
        return fd
    }
}
