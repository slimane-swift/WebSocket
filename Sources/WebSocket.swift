// The MIT License (MIT)
//
// Copyright (c) 2015 Zewo
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

@_exported import HTTPCore

public enum WebSocketError: Error {
    case noFrame
    case invalidOpCode
    case maskedFrameFromServer
    case unaskedFrameFromClient
    case controlFrameNotFinal
    case controlFrameInvalidLength
    case continuationOutOfOrder
    case dataFrameWithInvalidBits
    case maskKeyInvalidLength
    case noMaskKey
    case invalidUTF8Payload
    case invalidCloseCode
}

public final class WebSocket {
    private static let GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    
    public enum Mode {
        case server
        case client
    }
    
    private enum State {
        case header
        case headerExtra
        case payload
    }
    
    private enum CloseState {
        case open
        case serverClose
        case clientClose
    }
    
    public let mode: Mode
    public var storage: [String: Any] = [:]
    // public let request: Request
    // public let response: Response
    private let stream: DuplexStream
    private var state: State = .header
    private var closeState: CloseState = .open
    
    private var incompleteFrame: Frame?
    private var continuationFrames: [Frame] = []
    
    private let binaryEventEmitter = EventEmitter<Data>()
    private let textEventEmitter = EventEmitter<String>()
    private let pingEventEmitter = EventEmitter<Data>()
    private let pongEventEmitter = EventEmitter<Data>()
    private let closeEventEmitter = EventEmitter<(code: CloseCode?, reason: String?)>()
    
    public init(stream: DuplexStream, mode: Mode) { //, request: Request, response: Response) {
        self.stream = stream
        self.mode = mode
        // self.request = request
        // self.response = response
    }
    
    public func onBinary(_ listen: @escaping EventListener<Data>.Listen) -> EventListener<Data> {
        return binaryEventEmitter.addListener(listen: listen)
    }
    
    public func onText(_ listen: @escaping EventListener<String>.Listen) -> EventListener<String> {
        return textEventEmitter.addListener(listen: listen)
    }
    
    public func onPing(_ listen: @escaping EventListener<Data>.Listen) -> EventListener<Data> {
        return pingEventEmitter.addListener(listen: listen)
    }
    
    public func onPong(_ listen: @escaping EventListener<Data>.Listen) -> EventListener<Data> {
        return pongEventEmitter.addListener(listen: listen)
    }
    
    public func onClose(_ listen: @escaping EventListener<(code: CloseCode?, reason: String?)>.Listen) -> EventListener<(code: CloseCode?, reason: String?)> {
        return closeEventEmitter.addListener(listen: listen)
    }
    
    public func send(_ string: String, completion: @escaping (Result<Void>) -> Void = {_ in}) {
        send(.text, data: string.data, completion: completion)
    }
    
    public func send(_ data: Data, completion: @escaping (Result<Void>) -> Void = {_ in}) {
        send(.binary, data: data, completion: completion)
    }
    
    public func send(_ convertible: DataConvertible, completion: @escaping (Result<Void>) -> Void = {_ in}) {
        send(.binary, data: convertible.data, completion: completion)
    }
    
    public func close(_ code: CloseCode = .normal, reason: String? = nil) throws {
        if closeState == .serverClose {
            return
        }
        
        if closeState == .open {
            closeState = .serverClose
        }
        
        var data = Data(number: code.code)
        
        if let reason = reason {
            data.append(reason.data)
        }
        
        if closeState == .serverClose && code == .protocolError {
            stream.close()
        }
        
        send(.close, data: data)
        
        if closeState == .clientClose {
            stream.close()
        }
    }
    
    public func ping(_ data: Data = [], completion: @escaping (Result<Void>) -> Void = {_ in}) {
        send(.ping, data: data, completion: completion)
    }
    
    public func ping(_ convertible: DataConvertible, completion: @escaping (Result<Void>) -> Void = {_ in}) {
        send(.ping, data: convertible.data, completion: completion)
    }
    
    public func pong(_ data: Data = [], completion: @escaping (Result<Void>) -> Void = {_ in}) {
        send(.pong, data: data, completion: completion)
    }
    
    public func pong(_ convertible: DataConvertible, completion: @escaping (Result<Void>) -> Void = {_ in}) {
        send(.pong, data: convertible.data, completion: completion)
    }
    
    public func start() {
        stream.read(upTo: 4096, deadline: .never) { [weak self] in
            guard let _self = self else {
                return
            }
            do {
                switch $0 {
                case .success(let data):
                    try _self.processData(data)
                case .failure(let error):
                    throw error
                }
            } catch StreamError.closedStream {
                return
            } catch {
                do { try _self.closeEventEmitter.emit((code: .abnormal, reason: nil)) } catch {}
            }
        }
    }
    
    private func processData(_ data: Data) throws {
        guard data.count > 0 else {
            return
        }
        
        var totalBytesRead = 0
        
        while totalBytesRead < data.count {
            let bytesRead = try readBytes(Data(data[totalBytesRead ..< data.count]))
            
            if bytesRead == 0 {
                break
            }
            
            totalBytesRead += bytesRead
        }
    }
    
    private func readBytes(_ data: Data) throws -> Int {
        if data.count == 0 {
            return 0
        }
        
        var remainingData = data
        
        repeat {
            if incompleteFrame == nil {
                incompleteFrame = Frame()
            }
            
            // Use ! because if let will add data to a copy of the frame
            remainingData = incompleteFrame!.add(data: remainingData)
            
            if incompleteFrame!.isComplete {
                try validateFrame(incompleteFrame!)
                try processFrame(incompleteFrame!)
                incompleteFrame = nil
            }
        } while remainingData.count > 0
        
        return data.count
    }
    
    private func validateFrame(_ frame: Frame) throws {
        func fail(_ error: Error) throws -> Error {
            try close(.protocolError)
            return error
        }
        
        guard !frame.rsv1 && !frame.rsv2 && !frame.rsv3 else {
            throw try fail(WebSocketError.dataFrameWithInvalidBits)
        }
        
        guard frame.opCode != .invalid else {
            throw try fail(WebSocketError.invalidOpCode)
        }
        
        guard !frame.masked || self.mode == .server else {
            throw try fail(WebSocketError.maskedFrameFromServer)
        }
        
        guard frame.masked || self.mode == .client else {
            throw try fail(WebSocketError.unaskedFrameFromClient)
        }
        
        if frame.opCode.isControl {
            guard frame.fin else {
                throw try fail(WebSocketError.controlFrameNotFinal)
            }
            
            guard frame.payloadLength < 126 else {
                throw try fail(WebSocketError.controlFrameInvalidLength)
            }
            
            if frame.opCode == .close && frame.payloadLength == 1 {
                throw try fail(WebSocketError.controlFrameInvalidLength)
            }
        } else {
            if frame.opCode == .continuation && continuationFrames.isEmpty {
                throw try fail(WebSocketError.continuationOutOfOrder)
            }
            
            if frame.opCode != .continuation && !continuationFrames.isEmpty {
                throw try fail(WebSocketError.continuationOutOfOrder)
            }
            
            
        }
    }
    
    private func processFrame(_ frame: Frame) throws {
        func fail(_ error: Error) throws -> Error{
            try close(.protocolError)
            return error
        }
        
        if !frame.opCode.isControl {
            continuationFrames.append(frame)
        }
        
        if !frame.fin {
            return
        }
        
        var opCode = frame.opCode
        
        
        if frame.opCode == .continuation {
            let firstFrame = continuationFrames.first!
            opCode = firstFrame.opCode
        }
        
        switch opCode {
        case .binary:
            try binaryEventEmitter.emit(continuationFrames.payload)
        case .text:
            if (try? String(data: continuationFrames.payload)) == nil {
                throw try fail(WebSocketError.invalidUTF8Payload)
            }
            try textEventEmitter.emit(try String(data: continuationFrames.payload))
        case .ping:
            try pingEventEmitter.emit(frame.payload)
        case .pong:
            try pongEventEmitter.emit(frame.payload)
        case .close:
            if self.closeState == .open {
                var rawCloseCode: UInt16?
                var closeReason: String?
                var data = frame.payload
                
                if data.count >= 2 {
                    rawCloseCode = UInt16(Data(data.prefix(2)).toInt(size: 2))
                    data.removeFirst(2)
                    
                    if data.count > 0 {
                        closeReason = try? String(data: data)
                    }
                    
                    if data.count > 0 && closeReason == nil {
                        throw try fail(WebSocketError.invalidUTF8Payload)
                    }
                }
                
                closeState = .clientClose
                
                if let rawCloseCode = rawCloseCode {
                    let closeCode = CloseCode(code: rawCloseCode)
                    if closeCode.isValid {
                        try close(closeCode, reason: closeReason)
                        try closeEventEmitter.emit((closeCode, closeReason))
                    } else {
                        throw try fail(WebSocketError.invalidCloseCode)
                    }
                } else {
                    try close(reason: nil)
                    try closeEventEmitter.emit((nil, nil))
                }
            } else if self.closeState == .serverClose {
                stream.close()
            }
        default:
            break
        }
        
        if !frame.opCode.isControl {
            continuationFrames.removeAll()
        }
    }
    
    private func send(_ opCode: Frame.OpCode, data: Data, completion: @escaping (Result<Void>) -> Void = { _ in }) {
        do {
            let maskKey: Data
            if mode == .client {
                maskKey = try Data(randomBytes: 4)
            } else {
                maskKey = []
            }
            let frame = Frame(opCode: opCode, data: data, maskKey: maskKey)
            let data = frame.data
            stream.write(data) { _ in
                completion(.success())
            }
        } catch {
            completion(.failure(error))
        }
    }
    
    public static func accept(_ key: String) -> String? {
        let hashed = sha1(Array((key + GUID).utf8))
        
        let encoded = Data(bytes: hashed).base64EncodedString(options: [])
        return encoded
    }
}
