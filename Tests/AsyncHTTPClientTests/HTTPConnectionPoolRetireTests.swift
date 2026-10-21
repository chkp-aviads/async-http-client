//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2026 Apple Inc. and the AsyncHTTPClient project authors
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
import NIOPosix
import XCTest

@testable import AsyncHTTPClient

/// Records the requests a retired pool hands back
final class RetireRecordingDelegate: HTTPConnectionPoolDelegate, Sendable {
    private let resubmitted = NIOLockedValueBox(0)
    var resubmittedCount: Int { self.resubmitted.withLockedValue { $0 } }

    func connectionPoolDidShutdown(_ pool: HTTPConnectionPool, unclean: Bool) {}

    func connectionPoolRetired(_ pool: HTTPConnectionPool, resubmit request: HTTPSchedulableRequest) {
        self.resubmitted.withLockedValue { $0 += 1 }
        request.fail(HTTPClientError.alreadyShutdown)
    }
}

class HTTPConnectionPoolRetireTests: XCTestCase {
    private func makeRequestBag(port: Int, eventLoop: EventLoop) throws -> RequestBag<ResponseAccumulator> {
        let request = try HTTPClient.Request(url: "http://localhost:\(port)")
        return try RequestBag(
            request: request,
            eventLoopPreference: .indifferent,
            task: .init(eventLoop: eventLoop, logger: .init(label: "test")),
            redirectHandler: nil,
            connectionDeadline: .distantFuture,
            requestOptions: .forTests(),
            delegate: ResponseAccumulator(request: request)
        )
    }

    func testIdlePoolIsRetiredOnlyOnceItsConnectionsClose_AndHandsLateRequestsBack() throws {
        let httpBin = HTTPBin()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        var configuration = HTTPClient.Configuration()
        configuration.connectionPool = .init(idleTimeout: .milliseconds(100))
        let delegate = RetireRecordingDelegate()
        let pool = HTTPConnectionPool(
            eventLoopGroup: eventLoopGroup,
            sslContextCache: .init(),
            tlsConfiguration: .none,
            clientConfiguration: configuration,
            key: .init(try HTTPClient.Request(url: "http://localhost:\(httpBin.port)")),
            delegate: delegate,
            idGenerator: .init(),
            backgroundActivityLogger: .init(label: "test")
        )

        let first = try self.makeRequestBag(port: httpBin.port, eventLoop: eventLoop)
        pool.executeRequest(first)
        XCTAssertNoThrow(try first.task.futureResult.wait())
        XCTAssertFalse(pool.retireIfIdle(), "An open idle connection keeps the pool")

        // Let the idle timeout close the connection
        XCTAssertNoThrow(try eventLoop.scheduleTask(in: .milliseconds(400)) {}.futureResult.wait())
        XCTAssertEqual(httpBin.activeConnections, 0)
        XCTAssertTrue(pool.retireIfIdle(), "No connections and no requests: the pool is retired")
        XCTAssertFalse(pool.retireIfIdle(), "A pool is retired only once")

        // A request that still reaches the retired pool is handed back instead of being executed there
        let late = try self.makeRequestBag(port: httpBin.port, eventLoop: eventLoop)
        pool.executeRequest(late)
        XCTAssertThrowsError(try late.task.futureResult.wait())
        XCTAssertEqual(delegate.resubmittedCount, 1)
        XCTAssertEqual(httpBin.createdConnections, 1, "The retired pool created no new connection")
    }
}

class HTTPClientReleaseIdlePoolsTests: XCTestCase {
    func testReleaseIdleConnectionPoolsReleasesOnlyIdlePools() throws {
        let httpBin = HTTPBin()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }
        var configuration = HTTPClient.Configuration()
        configuration.connectionPool = .init(idleTimeout: .milliseconds(100))
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        XCTAssertNoThrow(try client.get(url: "http://localhost:\(httpBin.port)/get").wait())
        XCTAssertEqual(client.releaseIdleConnectionPools(), 0, "The pool still has its idle keep-alive connection")

        // Let the idle timeout close the connection
        XCTAssertNoThrow(try client.eventLoopGroup.next().scheduleTask(in: .milliseconds(400)) {}.futureResult.wait())
        XCTAssertEqual(client.releaseIdleConnectionPools(), 1)
        XCTAssertEqual(client.releaseIdleConnectionPools(), 0)

        // The host still works: a new pool is created for it
        XCTAssertNoThrow(try client.get(url: "http://localhost:\(httpBin.port)/get").wait())
        XCTAssertEqual(httpBin.createdConnections, 2)
    }
}
