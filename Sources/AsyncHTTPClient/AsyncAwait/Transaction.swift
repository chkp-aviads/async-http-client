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

import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOSSL

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
@usableFromInline
final class Transaction:
    // until NIOLockedValueBox learns `sending` because StateMachine cannot be Sendable
    @unchecked Sendable
{
    let logger: Logger

    let request: HTTPClientRequest.Prepared

    let connectionDeadline: NIODeadline
    let preferredEventLoop: EventLoop
    let requestOptions: RequestOptions
    var resolvedEndpoint: SocketAddress?

    private let state: NIOLockedValueBox<StateMachine>

    init(
        request: HTTPClientRequest.Prepared,
        requestOptions: RequestOptions,
        logger: Logger,
        connectionDeadline: NIODeadline,
        preferredEventLoop: EventLoop,
        responseContinuation: CheckedContinuation<HTTPClientResponse, Error>
    ) {
        self.request = request
        self.requestOptions = requestOptions
        self.logger = logger
        self.connectionDeadline = connectionDeadline
        self.preferredEventLoop = preferredEventLoop
        self.state = NIOLockedValueBox(StateMachine(responseContinuation))
    }

    func cancel() {
        self.fail(CancellationError())
    }

    // MARK: Request body helpers

    private func writeOnceAndOneTimeOnly(byteBuffer: ByteBuffer) {
        // This method is synchronously invoked after sending the request head. For this reason we
        // can make a number of assumptions, how the state machine will react.
        let writeAction = self.state.withLockedValue { state in
            state.writeNextRequestPart()
        }

        switch writeAction {
        case .writeAndWait(let executor), .writeAndContinue(let executor):
            executor.writeRequestBodyPart(.byteBuffer(byteBuffer), request: self, promise: nil)

        case .fail:
            // an error/cancellation has happened. we don't need to continue here
            return
        }

        self.requestBodyStreamFinished()
    }

    private func continueRequestBodyStream(
        _ allocator: ByteBufferAllocator,
        makeAsyncIterator: @Sendable @escaping () -> ((ByteBufferAllocator) async throws -> ByteBuffer?)
    ) {
        Task {
            let next = makeAsyncIterator()

            do {
                while let part = try await next(allocator) {
                    do {
                        try await self.writeRequestBodyPart(part)
                    } catch {
                        // If a write fails, the request has failed somewhere else. We must exit the
                        // write loop though. We don't need to report the error somewhere.
                        return
                    }
                }

                self.requestBodyStreamFinished()
            } catch {
                // The only chance of reaching this catch block, is an error thrown in the `next`
                // call above.
                self.requestBodyStreamFailed(error)
            }
        }
    }

    struct BreakTheWriteLoopError: Swift.Error {}

    // FIXME: Refactor this to not use `self.state.unsafe`.
    private func writeRequestBodyPart(_ part: ByteBuffer) async throws {
        self.state.unsafe.lock()
        switch self.state.unsafe.withValueAssumingLockIsAcquired({ state in state.writeNextRequestPart() }) {
        case .writeAndContinue(let executor):
            self.state.unsafe.unlock()
            executor.writeRequestBodyPart(.byteBuffer(part), request: self, promise: nil)

        case .writeAndWait(let executor):
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.state.unsafe.withValueAssumingLockIsAcquired({ state in
                    state.waitForRequestBodyDemand(continuation: continuation)
                })
                self.state.unsafe.unlock()

                executor.writeRequestBodyPart(.byteBuffer(part), request: self, promise: nil)
            }

        case .fail:
            self.state.unsafe.unlock()
            throw BreakTheWriteLoopError()
        }
    }

    private func requestBodyStreamFinished() {
        let finishAction = self.state.withLockedValue { state in
            state.finishRequestBodyStream()
        }

        switch finishAction {
        case .none:
            // an error/cancellation has happened. nothing to do.
            break

        case .forwardStreamFinished(let executor):
            executor.finishRequestBodyStream(self, promise: nil)
        }
        return
    }

    private func requestBodyStreamFailed(_ error: Error) {
        self.fail(error)
    }
}

// MARK: - Protocol Methods -

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Transaction: HTTPSchedulableRequest {
    var poolKey: ConnectionPool.Key { self.request.poolKey }
    var tlsConfiguration: TLSConfiguration? { self.request.tlsConfiguration }
    var requiredEventLoop: EventLoop? { nil }

    func requestWasQueued(_ scheduler: HTTPRequestScheduler) {
        self.state.withLockedValue { state in
            state.requestWasQueued(scheduler)
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Transaction: HTTPExecutableRequest {
    var requestHead: HTTPRequestHead { self.request.head }

    var requestFramingMetadata: RequestFramingMetadata { self.request.requestFramingMetadata }

    // MARK: Request

    func willExecuteRequest(_ executor: HTTPRequestExecutor) {
        let action = self.state.withLockedValue { state in
            state.willExecuteRequest(executor)
        }

        switch action {
        case .cancel(let executor):
            executor.cancelRequest(self)
        case .cancelAndFail(let executor, let continuation, with: let error):
            executor.cancelRequest(self)
            continuation.resume(throwing: error)
        case .none:
            break
        }
    }
    
    func requestResolvedToEndpoint(_ address: SocketAddress) {
        self.resolvedEndpoint = address
    }

    func requestHeadSent() {}

    func resumeRequestBodyStream() {
        let action = self.state.withLockedValue { state in
            state.resumeRequestBodyStream()
        }

        switch action {
        case .none:
            break

        case .startStream(let allocator):
            switch self.request.body {
            case .asyncSequence(_, let makeAsyncIterator):
                // it is safe to call this async here. it dispatches...
                self.continueRequestBodyStream(allocator, makeAsyncIterator: makeAsyncIterator)

            case .byteBuffer(let byteBuffer):
                self.writeOnceAndOneTimeOnly(byteBuffer: byteBuffer)

            case .none:
                break

            case .sequence(_, _, let create):
                let byteBuffer = create(allocator)
                self.writeOnceAndOneTimeOnly(byteBuffer: byteBuffer)
            }

        case .resumeStream(let continuation):
            continuation.resume(returning: ())
        }
    }

    func pauseRequestBodyStream() {
        self.state.withLockedValue { state in
            state.pauseRequestBodyStream()
        }
    }

    // MARK: Response

    func receiveResponseHead(_ head: HTTPResponseHead) {
        let action = self.state.withLockedValue { state in
            state.receiveResponseHead(head, delegate: self)
        }

        switch action {
        case .none:
            break

        case .succeedResponseHead(let body, let continuation):
            let response = HTTPClientResponse(
                requestMethod: self.requestHead.method,
                version: head.version,
                status: head.status,
                headers: head.headers,
                body: body,
                history: [],
                resolvedEndpoint: self.resolvedEndpoint
            )
            continuation.resume(returning: response)
        }
    }

    func receiveResponseBodyParts(_ buffer: CircularBuffer<ByteBuffer>) {
        let action = self.state.withLockedValue { state in
            state.receiveResponseBodyParts(buffer)
        }
        switch action {
        case .none:
            break
        case .yieldResponseBodyParts(let source, let responseBodyParts, let executer):
            switch source.yield(contentsOf: responseBodyParts) {
            case .dropped, .stopProducing:
                break
            case .produceMore:
                executer.demandResponseBodyStream(self)
            }
        }
    }

    func succeedRequest(_ buffer: CircularBuffer<ByteBuffer>?) {
        let succeedAction = self.state.withLockedValue { state in
            state.succeedRequest(buffer)
        }
        switch succeedAction {
        case .finishResponseStream(let source, let finalResponse):
            if let finalResponse = finalResponse {
                _ = source.yield(contentsOf: finalResponse)
            }
            source.finish()

        case .none:
            break
        }
    }

    func fail(_ error: Error) {
        let action = self.state.withLockedValue { state in
            state.fail(error)
        }
        self.performFailAction(action)
    }

    private func performFailAction(_ action: StateMachine.FailAction) {
        switch action {
        case .none:
            break

        case .failResponseHead(let continuation, let error, let scheduler, let executor, let bodyStreamContinuation):
            continuation.resume(throwing: error)
            bodyStreamContinuation?.resume(throwing: error)
            scheduler?.cancelRequest(self)  // NOTE: scheduler and executor are exclusive here
            executor?.cancelRequest(self)

        case .failResponseStream(let source, let error, let executor, let requestBodyStreamContinuation):
            source.finish(error)
            requestBodyStreamContinuation?.resume(throwing: error)
            executor.cancelRequest(self)

        case .failRequestStreamContinuation(let bodyStreamContinuation, let error):
            bodyStreamContinuation.resume(throwing: error)
        }
    }

    func deadlineExceeded() {
        let action = self.state.withLockedValue { state in
            state.deadlineExceeded()
        }
        self.performDeadlineExceededAction(action)
    }

    private func performDeadlineExceededAction(_ action: StateMachine.DeadlineExceededAction) {
        switch action {
        case .cancel(let requestContinuation, let scheduler, let executor, let bodyStreamContinuation):
            requestContinuation.resume(throwing: HTTPClientError.deadlineExceeded)
            scheduler?.cancelRequest(self)
            executor?.cancelRequest(self)
            bodyStreamContinuation?.resume(throwing: HTTPClientError.deadlineExceeded)
        case .cancelSchedulerOnly(let scheduler):
            scheduler.cancelRequest(self)
        case .none:
            break
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Transaction: NIOAsyncSequenceProducerDelegate {
    @usableFromInline
    func produceMore() {
        let action = self.state.withLockedValue { state in
            state.produceMore()
        }
        switch action {
        case .none:
            break
        case .requestMoreResponseBodyParts(let executer):
            executer.demandResponseBodyStream(self)
        }
    }

    @usableFromInline
    func didTerminate() {
        self.fail(HTTPClientError.cancelled)
    }
}
