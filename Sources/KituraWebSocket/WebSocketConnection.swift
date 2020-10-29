/*
 * Copyright IBM Corporation 2016, 2017, 2018
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import KituraNet
import NIO
import NIOWebSocket
import Foundation
import NIOHTTP1
import LoggerAPI
import NIOConcurrencyHelpers

public class WebSocketConnection {

    enum MessageState {
        case binary, text, unknown
    }

    private var messageState: MessageState = .unknown

    weak var service: WebSocketService?

    public let id = UUID().uuidString

    public let request: ServerRequest

    var awaitClose = false

    var message: ByteBuffer?

    weak var context: ChannelHandlerContext?
    
    // A connection timeout configured by the WebSocketService
    private let connectionTimeout: Int?

    // Are we waiting for a pong in response to a heartbeat ping?
    private var waitingForPong: Bool = false
    
    private var errors : [String] = []

    private var disconnectedFired: Bool = false

    init(request: ServerRequest, service: WebSocketService? = nil) {
        self.request = request
        self.connectionTimeout = service?.connectionTimeout
    }

    public func close(reason: WebSocketCloseReasonCode? = nil, description: String? = nil) {
        closeConnection(reason: reason?.webSocketErrorCode(), description: description, hard: false)
    }

    public func drop(reason: WebSocketCloseReasonCode? = nil, description: String? = nil) {
        closeConnection(reason: reason?.webSocketErrorCode(), description: description, hard: true)
    }

    public func ping(withMessage: String? = nil) {
        guard let context = context else {
            return
        }
        context.eventLoop.execute {
            if let message = withMessage {
                var buffer = context.channel.allocator.buffer(capacity: message.count)
                buffer.writeString(message)
                self.sendMessage(with: .ping, data: buffer)
            } else {
                let emptyBuffer = context.channel.allocator.buffer(capacity: 1)
                self.sendMessage(with: .ping, data: emptyBuffer)
            }
        }
    }

    public func send(message: Data, asBinary: Bool = true) {
        guard let context = context else {
            return
        }
        context.eventLoop.execute {
            var buffer = context.channel.allocator.buffer(capacity: message.count)
            buffer.writeBytes(message)
            self.sendMessage(with: asBinary ? .binary : .text, data: buffer)
        }
    }

    public func send(message: String) {
        guard let context = context else {
            return
        }
        context.eventLoop.execute {
            var buffer = context.channel.allocator.buffer(capacity: message.count)
            buffer.writeString(message)
            self.sendMessage(with: .text, data: buffer)
        }
    }
}

extension WebSocketConnection: ChannelInboundHandler {
    public typealias InboundIn = WebSocketFrame
    public typealias OutboundOut = WebSocketFrame

    public func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        guard context.channel.isActive else { return }
        if let timeout = self.connectionTimeout {
            let idleStateHandler = IdleStateHandler(allTimeout: TimeAmount.seconds(Int64(timeout/2)))
            context.pipeline.addHandler(idleStateHandler, position: .before(self)).whenComplete { _ in }
        }
        self.fireConnected()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {

        // Are no extensions negotiated with WebSocket upgrade request
        let hasNoExtensions = self.hasNoExtensionsConfigured(request: self.request)

        let frame = self.unwrapInboundIn(data)

        do {
            try validateRSV(frame: frame, hasNoExtensions: hasNoExtensions)
        } catch {
            connectionClosed(reason: .protocolError, description: "\(errors.joined(separator: ",")) must be 0 unless negotiated to define meaning for non-zero values")
        }

        var data = unmaskedData(frame: frame)
        switch frame.opcode {
        case .text:
            guard messageState == .unknown else {
                connectionClosed(reason: .protocolError, description: "A text frame must be the first in the message")
                return
            }

            guard frame.maskKey != nil else {
                connectionClosed(reason: .protocolError, description: "Received a frame from a client that wasn't masked")
                return
            }

            if frame.fin {
                if let utf8Text = data.getString(at: 0, length: data.readableBytes, encoding: .utf8) {
                    //If text is an empty string, the client might have sent the null character u{00}
                    var text = utf8Text
                    if text == "" {
                        text = data.getString(at: 0, length: data.readableBytes) ?? ""
                    }
                    fireReceivedString(message: text)
                    } else {
                        closeConnection(reason: .dataInconsistentWithMessage, description: "Failed to convert received payload to UTF-8 String", hard: true)
                    }
            } else {
                message =  context.channel.allocator.buffer(capacity: data.readableBytes)
                var buffer = data
                messageState = .text
                message?.writeBuffer(&buffer)
            }

        case .binary:
            guard messageState == .unknown else {
                connectionClosed(reason: .protocolError, description: "A binary frame must be the first in the message")
                return
            }

            guard frame.maskKey != nil else {
                connectionClosed(reason: .protocolError, description: "Received a frame from a client that wasn't masked")
                return
            }

            if frame.fin {
                fireReceivedData(data: data.getData(at: 0, length: data.readableBytes) ?? Data())
            } else {
                message =  context.channel.allocator.buffer(capacity: data.readableBytes)
                message?.writeBuffer(&data)
                messageState = .binary
            }

        case .continuation:
            guard messageState != .unknown else {
                connectionClosed(reason: .protocolError, description: "Continuation sent with prior binary or text frame")
                return
            }

            message?.writeBuffer(&data)
            guard let message = message else { return }

            if frame.fin {
                switch messageState {
                case .binary:
                    fireReceivedData(data: message.getData(at: 0, length: message.readableBytes) ?? Data())
                case .text:
                    if let text = message.getString(at: 0, length: message.readableBytes, encoding: .utf8) {
                        fireReceivedString(message: text)
                    } else {
                        connectionClosed(reason: .dataInconsistentWithMessage, description: "Failed to convert received payload to UTF-8 String")
                    }
                case .unknown: //not possible
                    break
                }
                messageState = .unknown
            }

        case .connectionClose:
            if self.context != nil {
                let reasonCode: WebSocketErrorCode
                var description: String?
                if frame.length >= 2 && frame.length < 126 {
                    reasonCode = data.readWebSocketErrorCode()?.protocolErrorIfInvalid() ?? WebSocketErrorCode.unknown(0)
                    description = data.getString(at: data.readerIndex, length: data.readableBytes, encoding: .utf8)
                    if description == nil {
                        closeConnection(reason: .dataInconsistentWithMessage, description: "Failed to convert received close message to UTF-8 String", hard: true)
                        return
                    }
                } else if frame.length == 0 {
                    reasonCode = .normalClosure
                } else {
                    connectionClosed(reason: .protocolError, description: "Close frames, that have a payload, must be between 2 and 125 octets inclusive")
                    return
                }
                connectionClosed(reason: reasonCode, description: description)
            }

        case .ping:
            guard frame.length < 126 else {
                connectionClosed(reason: .protocolError, description: "Control frames are only allowed to have payload up to and including 125 octets")
                return
            }

            guard frame.fin else {
                connectionClosed(reason: .protocolError, description: "Control frames must not be fragmented")
                return
            }
            sendMessage(with: .pong, data: data)

        case .pong:
            // If we were expecting this pong, following a heartbeat ping, don't expect it anymore.
            if self.waitingForPong {
                self.waitingForPong = false
            }

        case let code where code.isControlOpcode:
            let intCode = Int(webSocketOpcode: code)
            closeConnection(reason: .protocolError, description: "Parsed a frame with an invalid operation code of \(intCode)", hard: true)

        case let code:
            let intCode = Int(webSocketOpcode: code)
            closeConnection(reason: .protocolError, description: "Parsed a frame with an invalid operation code of \(intCode)", hard: true)
        }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard event is IdleStateHandler.IdleStateEvent else {
            context.fireUserInboundEventTriggered(event)
            return
        }

        if self.waitingForPong {
            _ = context.channel.close(mode: .all)
        } else {
            self.sendMessage(with: .ping, data: context.channel.allocator.buffer(capacity: 2))
            self.waitingForPong = true
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard let _error = error as? NIOWebSocketError else {
            Log.error("A non-NIOWebSocketError error was encountered: \(error). The channel will be closed.")
            closeConnection(reason: .unexpectedServerError, description: "\(error)", hard: true)
            return
        }
        switch _error {
        case .multiByteControlFrameLength:
            connectionClosed(reason: .protocolError, description: "Control frames are only allowed to have payload up to and including 125 octets")
        case .fragmentedControlFrame:
            connectionClosed(reason: .protocolError, description: "Control frames must not be fragmented")
        case .invalidFrameLength:
            connectionClosed(reason: .protocolError, description: "Frames must be smaller than the configured maximum acceptable frame size")
        }
    }
    public func channelInactive(context: ChannelHandlerContext) {
        if disconnectedFired == false {
            service?.disconnected(connection: self, reason: .noReasonCodeSent)
            disconnectedFired = true
        }
    }

    private func unmaskedData(frame: WebSocketFrame) -> ByteBuffer {
       var frameData = frame.data
       if let maskingKey = frame.maskKey {
           frameData.webSocketUnmask(maskingKey)
       }
       return frameData
    }

    private enum RSVError: Error {
        case invalidRSV
    }

    private func validateRSV(frame: WebSocketFrame, hasNoExtensions: Bool) throws {

        if hasNoExtensions && frame.rsv1 {
            errors.append("RSV1")
        }

        if frame.rsv2 {
            errors.append("RSV2")
        }

        if frame.rsv3 {
            errors.append("RSV3")
        }

        guard errors.isEmpty else {
            throw RSVError.invalidRSV
        }
    }

    // HTTP upgrade request header has no extensions configured
    private func hasNoExtensionsConfigured(request: ServerRequest) -> Bool {
        if let hasNoExtensions = request.headers["sec-websocket-extensions"]?.first?.split(separator: ";").first {
            return hasNoExtensions != "permessage-deflate"
        }
        return true
    }
}
extension WebSocketConnection {
    func connectionClosed(reason: WebSocketErrorCode, description: String? = nil, reasonToSendBack: WebSocketErrorCode? = nil) {
        guard let context = context else {
             return
        }
        if context.channel.isWritable {
            closeConnection(reason: reasonToSendBack ?? reason, description: description, hard: true)
            if disconnectedFired == false {
                fireDisconnected(reason: reason)
                disconnectedFired = true
            }
        } else {
            context.close(promise: nil)
        }
    }

    func sendMessage(with opcode: WebSocketOpcode, data: ByteBuffer) {
        guard let context = context else {
            return
        }
        guard context.channel.isWritable else {
            //TODO: Log an error
            return
        }

        guard !self.awaitClose else {
            //TODO: Log an error
            return
        }

        let frame = WebSocketFrame(fin: true, opcode: opcode, data: data)
        context.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
    }

    func closeConnection(reason: WebSocketErrorCode?, description: String?, hard: Bool) {
         guard let context = context else {
             return
         }
         var data = context.channel.allocator.buffer(capacity: 2)
         data.write(webSocketErrorCode: reason ?? .normalClosure)
         if let description = description {
             data.writeString(description)
         }

         let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
         let promise = context.eventLoop.makePromise(of: Void.self)
         context.writeAndFlush(self.wrapOutboundOut(frame), promise: promise)
         if hard {
            promise.futureResult.flatMap { _ in
                context.close(mode: .output)
            }.whenComplete { _ in }
         }
         awaitClose = true
    }
}

//  Callbacks to the WebSocketService
extension WebSocketConnection {
    func fireConnected() {
        service?.connected(connection: self)
    }

    func fireDisconnected(reason: WebSocketErrorCode) {
        service?.disconnected(connection: self, reason: WebSocketCloseReasonCode.from(webSocketErrorCode: reason))
    }

    func fireReceivedString(message: String) {
        service?.received(message: message, from: self)
    }

    func fireReceivedData(data: Data) {
        service?.received(message: data, from: self)
    }
}

extension WebSocketCloseReasonCode {
    func webSocketErrorCode() -> WebSocketErrorCode {
        let code = Int(self.code())
        return WebSocketErrorCode(codeNumber: code)
    }

    static func from(webSocketErrorCode: WebSocketErrorCode) -> WebSocketCloseReasonCode {
        switch webSocketErrorCode {
        case .normalClosure: return .normal
        case .goingAway: return .goingAway
        case .protocolError: return .protocolError
        case .unacceptableData: return .invalidDataType
        case .dataInconsistentWithMessage: return .invalidDataContents
        case .policyViolation: return .policyViolation
        case .messageTooLarge: return .messageTooLarge
        case .missingExtension: return .extensionMissing
        case .unexpectedServerError: return .serverError
        case .unknown(let code): return .userDefined(code)
        }
    }
}

extension WebSocketErrorCode {
    func protocolErrorIfInvalid() -> WebSocketErrorCode {
        //https://github.com/Kitura-Next/Kitura-WebSocket/pull/36
        if case .unknown(let code) = self, code < 3000 {
            return .protocolError
        }
        return self
    }
}
