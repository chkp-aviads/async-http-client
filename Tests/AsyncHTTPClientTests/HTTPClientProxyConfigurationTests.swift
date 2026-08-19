//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest

@testable import AsyncHTTPClient

final class HTTPClientProxyConfigurationTests: XCTestCase {
    private typealias Proxy = HTTPClient.Configuration.Proxy

    private let keyA: [[UInt8]] = [[UInt8](repeating: 0x01, count: 16), [UInt8](repeating: 0x02, count: 16)]
    private let keyB: [[UInt8]] = [[UInt8](repeating: 0x01, count: 16), [UInt8](repeating: 0xFE, count: 16)]

    /// `Proxy` is a stored field of the `Hashable` `ConnectionPool.Key`, and it implements `Hashable`
    /// by hand. If the Shadowsocks credentials were not part of the identity, two different servers
    /// reached at the same `host:port` would share pooled connections — traffic encrypted for the
    /// wrong user. Keeping the credentials inside `ProxyType` makes that automatic, and this test is
    /// what stops a future refactor from moving them out.
    func testShadowsocksCredentialsParticipateInEquality() {
        let first = Proxy.shadowsocksServer(host: "ss.example", port: 8388,
                                            method: "2022-blake3-aes-128-gcm", pskChain: keyA)
        let second = Proxy.shadowsocksServer(host: "ss.example", port: 8388,
                                             method: "2022-blake3-aes-128-gcm", pskChain: keyB)

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.hashValue, second.hashValue)
    }

    func testShadowsocksMethodParticipatesInEquality() {
        let aes128 = Proxy.shadowsocksServer(host: "ss.example", port: 8388,
                                             method: "2022-blake3-aes-128-gcm", pskChain: keyA)
        let aes256 = Proxy.shadowsocksServer(host: "ss.example", port: 8388,
                                             method: "2022-blake3-aes-256-gcm", pskChain: keyA)
        XCTAssertNotEqual(aes128, aes256)
    }

    func testIdenticalShadowsocksProxiesAreEqual() {
        let first = Proxy.shadowsocksServer(host: "ss.example", port: 8388,
                                            method: "2022-blake3-aes-128-gcm", pskChain: keyA)
        let second = Proxy.shadowsocksServer(host: "ss.example", port: 8388,
                                             method: "2022-blake3-aes-128-gcm", pskChain: keyA)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)
    }

    /// `name` is documented as debug-only and deliberately excluded from identity.
    func testNameDoesNotAffectEquality() {
        var first = Proxy.shadowsocksServer(host: "ss.example", port: 8388,
                                            method: "2022-blake3-aes-128-gcm", pskChain: keyA)
        first.name = "one"
        var second = Proxy.shadowsocksServer(host: "ss.example", port: 8388,
                                             method: "2022-blake3-aes-128-gcm", pskChain: keyA)
        second.name = "two"
        XCTAssertEqual(first, second)
    }

    /// Key material must not reach logs through interpolation. The default reflection-based rendering
    /// of an enum with an associated value would walk into the PSK chain, hence the hand-written
    /// `description` on both types.
    func testDescriptionsDoNotLeakKeyMaterial() {
        let proxy = Proxy.shadowsocksServer(host: "ss.example", port: 8388,
                                            method: "2022-blake3-aes-128-gcm", pskChain: keyA)
        for rendered in ["\(proxy.type)", "\(Proxy.Shadowsocks(method: "m", pskChain: keyA))"] {
            XCTAssertFalse(rendered.contains("1, 1, 1"), "rendered key bytes: \(rendered)")
            XCTAssertFalse(rendered.contains("["), "rendered a raw collection: \(rendered)")
        }
        XCTAssertEqual("\(proxy.type)", "shadowsocks(2022-blake3-aes-128-gcm)")
    }

    /// HTTP CONNECT tunnels TCP only; callers steering datagrams rely on this rather than comparing
    /// against `.http` so a new transport is handled correctly by default.
    func testSupportsUDPPerProxyType() {
        XCTAssertFalse(Proxy.server(host: "p.example", port: 3128).supportsUDP)
        XCTAssertTrue(Proxy.socksServer(host: "p.example", port: 1080).supportsUDP)
        XCTAssertTrue(
            Proxy.shadowsocksServer(host: "ss.example", port: 8388,
                                    method: "2022-blake3-aes-128-gcm", pskChain: keyA).supportsUDP
        )
    }
}
