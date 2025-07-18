//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2021 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOSOCKS

public final class SOCKSEventsHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = NIOAny

    enum State {
        // transitions to channelActive or failed
        case initialized
        // transitions to socksEstablished or failed
        case channelActive(Scheduled<Void>)
        // final success state
        case socksEstablished
        // final success state
        case failed(Error)
    }

    /// A promise that will be fulfilled when the SOCKS handshake is established.
    private var socksEstablishedPromise: EventLoopPromise<Void>?
    public var socksEstablishedFuture: EventLoopFuture<Void>? {
        self.socksEstablishedPromise?.futureResult
    }

    public var socksEstablishedEvent: SOCKSProxyEstablishedEvent?
    private let deadline: NIODeadline
    private var state: State = .initialized

    public init(deadline: NIODeadline) {
        self.deadline = deadline
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.socksEstablishedPromise = context.eventLoop.makePromise(of: Void.self)

        if context.channel.isActive {
            self.connectionStarted(context: context)
        }
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        struct NoResult: Error {}
        self.socksEstablishedPromise!.fail(NoResult())
    }

    public func channelActive(context: ChannelHandlerContext) {
        self.connectionStarted(context: context)
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let socksEstablishedEvent = event as? SOCKSProxyEstablishedEvent else {
            return context.fireUserInboundEventTriggered(event)
        }

        switch self.state {
        case .initialized:
            preconditionFailure("How can we establish a SOCKS connection, if we are not connected?")
        case .socksEstablished:
            preconditionFailure("`SOCKSProxyEstablishedEvent` must only be fired once.")
        case .channelActive(let scheduled):
            self.state = .socksEstablished
            self.socksEstablishedEvent = socksEstablishedEvent
            scheduled.cancel()
            self.socksEstablishedPromise?.succeed(())
            context.fireUserInboundEventTriggered(event)
        case .failed:
            // potentially a race with the timeout...
            break
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        switch self.state {
        case .initialized:
            self.state = .failed(error)
            self.socksEstablishedPromise?.fail(error)
        case .channelActive(let scheduled):
            scheduled.cancel()
            self.state = .failed(error)
            self.socksEstablishedPromise?.fail(error)
        case .socksEstablished, .failed:
            break
        }
        context.fireErrorCaught(error)
    }

    private func connectionStarted(context: ChannelHandlerContext) {
        guard case .initialized = self.state else {
            return
        }

        let scheduled = context.eventLoop.assumeIsolated().scheduleTask(deadline: self.deadline) {
            switch self.state {
            case .initialized, .channelActive:
                // close the connection, if the handshake timed out
                context.close(mode: .all, promise: nil)
                let error = HTTPClientError.socksHandshakeTimeout
                self.state = .failed(error)
                self.socksEstablishedPromise?.fail(error)
            case .failed, .socksEstablished:
                break
            }
        }

        self.state = .channelActive(scheduled)
    }
}
