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

import Atomics
import Logging
import NIOCore
import NIOPosix
import NIOSOCKS
import NIOSSL
import NIOTransportServices
import XCTest

@testable import AsyncHTTPClient

#if canImport(Network)
import Network
#endif

class HTTPConnectionPool_FactoryTests: XCTestCase {
    func testDNSResolverIsCalledDuringConnectionCreation() throws {
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try serverGroup.syncShutdownGracefully()) }

        let clientGroup = getDefaultEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try clientGroup.syncShutdownGracefully()) }

        var server: Channel?
        XCTAssertNoThrow(
            server = try ServerBootstrap(group: serverGroup)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(NeverrespondServerHandler())
                }
                .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
                .wait()
        )
        defer { XCTAssertNoThrow(try server?.close().wait()) }

        let dnsResolverCallCount = ManagedAtomic<Int>(0)
        let eventLoop = clientGroup.next()
        var configuration = HTTPClient.Configuration()
        configuration.dnsResolver = {
            dnsResolverCallCount.wrappingIncrement(ordering: .relaxed)
            return eventLoop.makeSucceededFuture(nil)
        }

        let request = try HTTPClient.Request(url: "http://localhost:\(server!.localAddress!.port!)")
        let factory = HTTPConnectionPool.ConnectionFactory(
            key: .init(request),
            tlsConfiguration: nil,
            clientConfiguration: configuration,
            sslContextCache: .init()
        )

        let negotiated = try factory.makeChannel(
            requester: ExplodingRequester(),
            connectionID: 1,
            deadline: .now() + .seconds(5),
            eventLoop: eventLoop,
            logger: .init(label: "test")
        ).wait()

        switch negotiated {
        case .http1_1(let channel), .http2(let channel):
            XCTAssertNoThrow(try channel.close().wait())
        }

        XCTAssertGreaterThan(
            dnsResolverCallCount.load(ordering: .relaxed),
            0,
            "Expected dnsResolver to be invoked during connection creation"
        )
    }

    func testNWParametersConfiguratorIsCalledWhenUsingNIOTSTLSBootstrap() throws {
        guard isTestingNIOTS() else { throw XCTSkip("NIOTS tests disabled") }

        #if canImport(Network)
        if #available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
            let group = getDefaultEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

            guard group is NIOTSEventLoopGroup else {
                throw XCTSkip("Not running with NIOTSEventLoopGroup")
            }

            let httpBin = HTTPBin(.http1_1(ssl: true))
            defer { XCTAssertNoThrow(try httpBin.shutdown()) }

            let configuratorCallCount = ManagedAtomic<Int>(0)
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = .none

            var configuration = HTTPClient.Configuration(tlsConfiguration: tlsConfig)
            configuration.nwParametersConfigurator = { _ in
                configuratorCallCount.wrappingIncrement(ordering: .relaxed)
            }

            let request = try HTTPClient.Request(url: "https://localhost:\(httpBin.port)/get")
            let factory = HTTPConnectionPool.ConnectionFactory(
                key: .init(request),
                tlsConfiguration: nil,
                clientConfiguration: configuration,
                sslContextCache: .init()
            )

            let negotiated = try factory.makeChannel(
                requester: ExplodingRequester(),
                connectionID: 1,
                deadline: .now() + .seconds(5),
                eventLoop: group.next(),
                logger: .init(label: "test")
            ).wait()

            switch negotiated {
            case .http1_1(let channel), .http2(let channel):
                XCTAssertNoThrow(try channel.close().wait())
            }

            XCTAssertGreaterThan(
                configuratorCallCount.load(ordering: .relaxed),
                0,
                "Expected nwParametersConfigurator to be invoked for NIOTS TLS bootstrap"
            )
        } else {
            throw XCTSkip("NIOTS requires newer OS")
        }
        #else
        throw XCTSkip("Network.framework not available")
        #endif
    }

    func testConfigureTlsOptionsIsCalledWhenUsingNIOTSTLSBootstrap() throws {
        guard isTestingNIOTS() else { throw XCTSkip("NIOTS tests disabled") }

        #if canImport(Network)
        if #available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
            let group = getDefaultEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

            guard group is NIOTSEventLoopGroup else {
                throw XCTSkip("Not running with NIOTSEventLoopGroup")
            }

            let httpBin = HTTPBin(.http1_1(ssl: true))
            defer { XCTAssertNoThrow(try httpBin.shutdown()) }

            let configureTlsOptionsCallCount = ManagedAtomic<Int>(0)
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = .none

            var configuration = HTTPClient.Configuration(tlsConfiguration: tlsConfig)
            configuration.configureTlsOptions = { _, _ in
                configureTlsOptionsCallCount.wrappingIncrement(ordering: .relaxed)
            }

            let request = try HTTPClient.Request(url: "https://localhost:\(httpBin.port)/get")
            let factory = HTTPConnectionPool.ConnectionFactory(
                key: .init(request),
                tlsConfiguration: nil,
                clientConfiguration: configuration,
                sslContextCache: .init()
            )

            let negotiated = try factory.makeChannel(
                requester: ExplodingRequester(),
                connectionID: 1,
                deadline: .now() + .seconds(5),
                eventLoop: group.next(),
                logger: .init(label: "test")
            ).wait()

            switch negotiated {
            case .http1_1(let channel), .http2(let channel):
                XCTAssertNoThrow(try channel.close().wait())
            }

            XCTAssertGreaterThan(
                configureTlsOptionsCallCount.load(ordering: .relaxed),
                0,
                "Expected configureTlsOptions to be invoked for NIOTS TLS bootstrap"
            )
        } else {
            throw XCTSkip("NIOTS requires newer OS")
        }
        #else
        throw XCTSkip("Network.framework not available")
        #endif
    }

    func testConnectionCreationTimesoutIfDeadlineIsInThePast() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        var server: Channel?
        XCTAssertNoThrow(
            server = try ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(NeverrespondServerHandler())
                }
                .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
                .wait()
        )
        defer {
            XCTAssertNoThrow(try server?.close().wait())
        }

        let request = try! HTTPClient.Request(url: "https://apple.com")

        let factory = HTTPConnectionPool.ConnectionFactory(
            key: .init(request),
            tlsConfiguration: nil,
            clientConfiguration: .init(proxy: .socksServer(host: "127.0.0.1", port: server!.localAddress!.port!)),
            sslContextCache: .init()
        )

        XCTAssertThrowsError(
            try factory.makeChannel(
                requester: ExplodingRequester(),
                connectionID: 1,
                deadline: .now() - .seconds(1),
                eventLoop: group.next(),
                logger: .init(label: "test")
            ).wait()
        ) {
            guard let error = $0 as? ChannelError, case .connectTimeout = error else {
                XCTFail("Unexpected error: \($0)")
                return
            }
        }
    }

    func testSOCKSConnectionCreationTimesoutIfRemoteIsUnresponsive() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        var server: Channel?
        XCTAssertNoThrow(
            server = try ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(NeverrespondServerHandler())
                }
                .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
                .wait()
        )
        defer {
            XCTAssertNoThrow(try server?.close().wait())
        }

        let request = try! HTTPClient.Request(url: "https://apple.com")

        let factory = HTTPConnectionPool.ConnectionFactory(
            key: .init(request),
            tlsConfiguration: nil,
            clientConfiguration: .init(proxy: .socksServer(host: "127.0.0.1", port: server!.localAddress!.port!))
                .enableFastFailureModeForTesting(),
            sslContextCache: .init()
        )

        XCTAssertThrowsError(
            try factory.makeChannel(
                requester: ExplodingRequester(),
                connectionID: 1,
                deadline: .now() + .seconds(1),
                eventLoop: group.next(),
                logger: .init(label: "test")
            ).wait()
        ) {
            XCTAssertEqual($0 as? HTTPClientError, .socksHandshakeTimeout)
        }
    }

    func testHTTPProxyConnectionCreationTimesoutIfRemoteIsUnresponsive() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        var server: Channel?
        XCTAssertNoThrow(
            server = try ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(NeverrespondServerHandler())
                }
                .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
                .wait()
        )
        defer {
            XCTAssertNoThrow(try server?.close().wait())
        }

        let request = try! HTTPClient.Request(url: "https://localhost:\(server!.localAddress!.port!)")

        let factory = HTTPConnectionPool.ConnectionFactory(
            key: .init(request),
            tlsConfiguration: nil,
            clientConfiguration: .init(proxy: .server(host: "127.0.0.1", port: server!.localAddress!.port!))
                .enableFastFailureModeForTesting(),
            sslContextCache: .init()
        )

        XCTAssertThrowsError(
            try factory.makeChannel(
                requester: ExplodingRequester(),
                connectionID: 1,
                deadline: .now() + .seconds(1),
                eventLoop: group.next(),
                logger: .init(label: "test")
            ).wait()
        ) {
            XCTAssertEqual($0 as? HTTPClientError, .httpProxyHandshakeTimeout)
        }
    }

    func testTLSConnectionCreationTimesoutIfRemoteIsUnresponsive() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        var server: Channel?
        XCTAssertNoThrow(
            server = try ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(NeverrespondServerHandler())
                }
                .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
                .wait()
        )
        defer {
            XCTAssertNoThrow(try server?.close().wait())
        }

        let request = try! HTTPClient.Request(url: "https://localhost:\(server!.localAddress!.port!)")

        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        let factory = HTTPConnectionPool.ConnectionFactory(
            key: .init(request),
            tlsConfiguration: nil,
            clientConfiguration: .init(tlsConfiguration: tlsConfig)
                .enableFastFailureModeForTesting(),
            sslContextCache: .init()
        )

        XCTAssertThrowsError(
            try factory.makeChannel(
                requester: ExplodingRequester(),
                connectionID: 1,
                deadline: .now() + .seconds(1),
                eventLoop: group.next(),
                logger: .init(label: "test")
            ).wait()
        ) {
            XCTAssertEqual($0 as? HTTPClientError, .tlsHandshakeTimeout)
        }
    }
}

final class NeverrespondServerHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = NIOAny

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // do nothing
    }
}

/// A `HTTPConnectionRequester` that will fail a test if any of its methods are ever called.
final class ExplodingRequester: HTTPConnectionRequester {
    func http1ConnectionCreated(_: HTTP1Connection.SendableView) {
        XCTFail("http1ConnectionCreated called unexpectedly")
    }

    func http2ConnectionCreated(_: HTTP2Connection.SendableView, maximumStreams: Int) {
        XCTFail("http2ConnectionCreated called unexpectedly")
    }

    func failedToCreateHTTPConnection(_: HTTPConnectionPool.Connection.ID, error: Error) {
        XCTFail("failedToCreateHTTPConnection called unexpectedly")
    }

    func waitingForConnectivity(_: HTTPConnectionPool.Connection.ID, error: Error) {
        XCTFail("waitingForConnectivity called unexpectedly")
    }
}

extension HTTPConnectionPool.ConnectionFactory {
    fileprivate func makeChannel<Requester: HTTPConnectionRequester>(
        requester: Requester,
        connectionID: HTTPConnectionPool.Connection.ID,
        deadline: NIODeadline,
        eventLoop: EventLoop,
        logger: Logger
    ) -> EventLoopFuture<NegotiatedProtocol> {
        let promise = eventLoop.makePromise(of: NegotiatedProtocol.self)
        self.makeChannel(
            requester: requester,
            connectionID: connectionID,
            deadline: deadline,
            eventLoop: eventLoop,
            logger: logger,
            promise: promise
        )
        return promise.futureResult
    }
}
