//
//  Socket.swift
//  FlyingFox
//
//  Created by Simon Whitty on 13/02/2022.
//  Copyright © 2022 Simon Whitty. All rights reserved.
//
//  Distributed under the permissive MIT license
//  Get the latest version from here:
//
//  https://github.com/swhitty/FlyingFox
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation

enum SocketError: Error {
    case createFailed(String)
    case optionsFailed(String)
    case flagsFailed(String)
    case bindFailed(String)
    case peerNameFailed(String)
    case nameInfoFailed(String)
    case addressFailed(String)
    case listenFailed(String)
    case acceptFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case closeFailed(String)
}

struct Socket: Sendable, Hashable {

    let file: Int32

    init(file: Int32) {
        self.file = file
    }

    init() throws {
        self.file = socket(AF_INET6, SOCK_STREAM, 0)
        if file == -1 {
            throw SocketError.createFailed(makeErrorMessage())
        }
    }

    var flags: Flags {
        Flags(rawValue: fcntl(file, F_GETFL))
    }

    func setFlags(_ flags: Flags) throws {
        if fcntl(file, F_SETFL, flags.rawValue) == -1 {
            throw SocketError.flagsFailed(makeErrorMessage())
        }
    }

    func enableOption<O: SocketOption>(_ option: O) throws {
        var value = option.value
        if setsockopt(file, SOL_SOCKET, option.option, &value, socklen_t(MemoryLayout<O.Value.Type>.size)) == -1 {
            throw SocketError.optionsFailed(makeErrorMessage())
        }
    }

    func bindIP6(port: UInt16, listenAddress: String? = nil) throws {
        var addr = sockaddr_in6(
            sin6_len: UInt8(MemoryLayout<sockaddr_in6>.stride),
            sin6_family: UInt8(AF_INET6),
            sin6_port: port.bigEndian,
            sin6_flowinfo: 0,
            sin6_addr: in6addr_any,
            sin6_scope_id: 0)

        if let address = listenAddress {
            guard address.withCString({ cstring in inet_pton(AF_INET6, cstring, &addr.sin6_addr) }) == 1 else {
                throw SocketError.bindFailed(makeErrorMessage())
            }
        }

        let result = withUnsafePointer(to: &addr) {
            bind(file, UnsafePointer<sockaddr>(OpaquePointer($0)), socklen_t(MemoryLayout<sockaddr_in6>.size))
        }

        if result == -1 {
            let message = makeErrorMessage()
            try close()
            throw SocketError.bindFailed(message)
        }
    }

    func listen(maxPendingConnection: Int32 = SOMAXCONN) throws {
        if Darwin.listen(file, maxPendingConnection) == -1 {
            let message = makeErrorMessage()
            try close()
            throw SocketError.listenFailed(message)
        }
    }

    func remoteHostname() throws -> String {
        var addr = sockaddr()
        var len = socklen_t(MemoryLayout<sockaddr>.size)
        if getpeername(file, &addr, &len) != 0 {
            throw SocketError.peerNameFailed(makeErrorMessage())
        }
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(&addr, len, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) != 0 {
            throw SocketError.nameInfoFailed(makeErrorMessage())
        }
        return String(cString: hostBuffer)
    }

    func accept() throws -> (file: Int32, addr: sockaddr)? {
        var addr = sockaddr()
        var len: socklen_t = 0
        let newFile = Darwin.accept(file, &addr, &len)

        if newFile == -1 {
            if errno == EWOULDBLOCK {
                return nil
            } else {
                throw SocketError.acceptFailed(makeErrorMessage())
            }
        }

        return (newFile, addr)
    }

    func read() throws -> UInt8? {
        var byte: UInt8 = 0
        let count = Darwin.read(file, &byte, 1)
        if count == 1 {
            return byte
        } else if errno == EWOULDBLOCK {
            return nil
        }
        else {
            throw SocketError.readFailed(makeErrorMessage())
        }
    }

    public func writeData(_ data: Data) throws {
        guard !data.isEmpty else { return }
        return try data.withUnsafeBytes {
            guard let baseAddress = $0.baseAddress else {
                throw SocketError.writeFailed("Invalid Buffer")
            }
            try write(baseAddress, length: data.count)
        }
    }

    private func write(_ pointer: UnsafeRawPointer, length: Int) throws {
        var sent = 0
        while sent < length {
            let result = Darwin.write(file, pointer + sent, Int(length - sent))
            if result <= 0 {
                throw SocketError.writeFailed(makeErrorMessage())
            }
            sent += result
        }
    }

    func close() throws {
        if Darwin.close(file) == -1 {
            throw SocketError.closeFailed(makeErrorMessage())
        }
    }

    private func makeErrorMessage() -> String {
        String(cString: strerror(errno))
    }
}

extension Socket {
    struct Flags: OptionSet {
        var rawValue: Int32

        static let nonBlocking = Flags(rawValue: O_NONBLOCK)
    }
}

protocol SocketOption {
    associatedtype Value

    var option: Int32 { get }
    var value: Value { get }
}

extension SocketOption where Self == Int32SocketOption {
    static var enableLocalAddressReuse: Self {
        Int32SocketOption(option: SO_REUSEADDR)
    }

    // Apple platforms only. Prevents crash when app is paused / running in background.
    static var enableNoSIGPIPE: Self {
        Int32SocketOption(option: SO_NOSIGPIPE)
    }
}

struct Int32SocketOption: SocketOption {
    var option: Int32
    var value: Int32 = 1
}
