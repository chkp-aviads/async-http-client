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

import NIOCore
import NIOHTTP1
import NIOSSL
import NIOShadowsocks

extension HTTPClient.Configuration {
    /// Proxy server configuration
    /// Specifies the remote address of an HTTP proxy.
    ///
    /// Adding an `Proxy` to your client's `HTTPClient.Configuration`
    /// will cause requests to be passed through the specified proxy using the
    /// HTTP `CONNECT` method.
    ///
    /// If a `TLSConfiguration` is used in conjunction with `HTTPClient.Configuration.Proxy`,
    /// TLS will be established _after_ successful proxy, between your client
    /// and the destination server.
    public struct Proxy: Sendable, Hashable {
        public enum ProxyType: Hashable, Sendable, CustomStringConvertible {
            case http
            case socks
            /// A Shadowsocks 2022 (SIP022) server.
            ///
            /// The configuration lives inside the case rather than in a sibling property because
            /// `Proxy` implements `Hashable` by hand and is a stored field of the `Hashable`
            /// `ConnectionPool.Key`: keeping it here means it is hashed and compared automatically, so
            /// two servers reached at the same `host:port` with different keys can never share a
            /// pooled connection because someone forgot to update `==`. It also makes a
            /// `.shadowsocks` proxy without credentials unrepresentable.
            case shadowsocks(ShadowsocksConfiguration)

            /// Deliberately hand-written: the default reflection-based rendering of an enum with an
            /// associated value would walk into the PSK chain and risk printing key material.
            public var description: String {
                switch self {
                case .http: return "http"
                case .socks: return "socks"
                case .shadowsocks(let configuration): return "shadowsocks(\(configuration.method.rawValue))"
                }
            }
        }

        /// Specifies Proxy server host.
        public var host: String
        /// Specifies Proxy server port.
        public var port: Int
        /// Proxy type
        public var type: ProxyType
        /// Specifies Proxy server authorization.
        public var authorization: HTTPClient.Authorization?

        /// An optional, human-readable name for this proxy, used for description/debugging purposes only.
        /// Not considered when comparing or hashing `Proxy` values.
        public var name: String?

        /// TLS configuration for the proxy server
        internal var internalTlsConfiguration: BestEffortHashableTLSConfiguration? = nil
        public var tlsConfiguration : TLSConfiguration? {
            get {
                internalTlsConfiguration?.base
            }
            set {
                if let newValue {
                    internalTlsConfiguration = .init(wrapping: newValue)
                } else {
                    internalTlsConfiguration = nil
                }
            }
        }

        /// Extra headers sent only on the HTTP `CONNECT` request to the proxy.
        ///
        /// These headers are not sent to the
        /// destination server, and are ignored for SOCKS proxies.
        /// The `host` and `proxy-authorization` headers cannot be overridden through this property
        /// Note: Excluded from hash, because HTTPHeaders are not hashable.
        public var connectHeaders: HTTPHeaders = [:]

        /// Create an HTTP proxy configuration.
        ///
        /// - parameters:
        ///     - host: proxy server host.
        ///     - port: proxy server port.
        ///     - authorization: proxy server authorization.
        ///     - connectHeaders: additional HTTP headers to send on the proxy `CONNECT` request.
        ///     - name: an optional, human-readable name for this proxy, used for description/debugging purposes only.
        public static func server(
            host: String,
            port: Int,
            authorization: HTTPClient.Authorization? = nil,
            connectHeaders: HTTPHeaders = [:],
            name: String? = nil
        ) -> Proxy {
            var proxy = Proxy(host: host, port: port, type: .http, authorization: authorization)
            proxy.connectHeaders = connectHeaders
            proxy.name = name
            return proxy
        }

        /// Create an HTTP proxy configuration.
        ///
        /// - parameters:
        ///     - host: proxy server host.
        ///     - port: proxy server port.
        ///     - authorization: proxy server authorization.
        ///     - connectHeaders: extra headers sent only on the `CONNECT` request to the proxy.
        public static func server(
            host: String,
            port: Int,
            authorization: HTTPClient.Authorization? = nil,
            connectHeaders: HTTPHeaders
        ) -> Self {
            var proxy = Self(host: host, port: port, type: .http)
            proxy.authorization = authorization
            proxy.connectHeaders = connectHeaders
            return proxy
        }

        /// Create a SOCKSv5 proxy configuration.
        /// - parameter host: The SOCKSv5 proxy address.
        /// - parameter port: The SOCKSv5 proxy port, defaults to 1080.
        /// - parameter name: an optional, human-readable name for this proxy, used for description/debugging purposes only.
        /// - returns: A new instance of `Proxy` configured to connect to a `SOCKSv5` server.
        public static func socksServer(host: String, port: Int = 1080, authorization: HTTPClient.Authorization? = nil, name: String? = nil) -> Proxy {
            var proxy = Proxy(host: host, port: port, type: .socks, authorization: authorization)
            proxy.name = name
            return proxy
        }

        /// Create a Shadowsocks 2022 (SIP022) proxy.
        ///
        /// - parameter host: The Shadowsocks server address.
        /// - parameter port: The Shadowsocks server port.
        /// - parameter configuration: The method and pre-shared key chain, already validated.
        /// - parameter name: an optional, human-readable name used for description/debugging only.
        public static func shadowsocksServer(
            host: String,
            port: Int,
            configuration: ShadowsocksConfiguration,
            name: String? = nil
        ) -> Proxy {
            var proxy = Proxy(
                host: host,
                port: port,
                type: .shadowsocks(configuration),
                authorization: nil
            )
            proxy.name = name
            return proxy
        }

        /// Whether this proxy can carry UDP as well as TCP.
        ///
        /// HTTP CONNECT can only tunnel TCP connections; SOCKSv5 has UDP ASSOCIATE and Shadowsocks
        /// carries UDP natively. Callers that steer datagrams should consult this rather than
        /// comparing against ``ProxyType/http`` so a new transport is handled correctly by default.
        public var supportsUDP: Bool {
            if case .http = self.type { return false }
            return true
        }

        public static func == (lhs: Proxy, rhs: Proxy) -> Bool {
            lhs.host == rhs.host
                && lhs.port == rhs.port
                && lhs.type == rhs.type
                && lhs.authorization == rhs.authorization
                && lhs.internalTlsConfiguration == rhs.internalTlsConfiguration
                && lhs.connectHeaders == rhs.connectHeaders
        }

        // `connectHeaders` is omitted (HTTPHeaders is not hashable)
        public func hash(into hasher: inout Hasher) {
            hasher.combine(self.host)
            hasher.combine(self.port)
            hasher.combine(self.type)
            hasher.combine(self.authorization)
            hasher.combine(self.internalTlsConfiguration)
        }
    }
}
