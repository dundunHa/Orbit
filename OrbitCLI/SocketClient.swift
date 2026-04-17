import Darwin
import Foundation

enum SocketClient {
    static func connectAndSend(socketPath: String, payload: String, waitForResponse: Bool) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < maxLength else { return nil }

        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: pathBytes)
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addrLen)
            }
        }
        guard connectResult == 0 else { return nil }

        let line = payload + "\n"
        let written = line.withCString { ptr in
            writeAll(fd: fd, bytes: ptr, count: line.utf8.count)
        }
        guard written else { return nil }

        guard waitForResponse else { return nil }

        return readLine(fd: fd)
    }

    private static func writeAll(fd: Int32, bytes: UnsafePointer<CChar>, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = write(fd, bytes.advanced(by: offset), count - offset)
            if n > 0 {
                offset += n
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    private static func readLine(fd: Int32) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(chunk, count: n)
                if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[..<newlineIndex]
                    return String(decoding: lineData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else if n == 0 {
                if buffer.isEmpty { return nil }
                return String(decoding: buffer, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
    }
}
