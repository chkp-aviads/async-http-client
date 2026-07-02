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
        public enum ProxyType: Hashable, Sendable {
            case http
            case socks
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

        /// Additional HTTP headers to send on the `CONNECT` request to an HTTP proxy.
        ///
        /// This can be used to set headers such as `User-Agent` on the proxy `CONNECT`
        /// request. These headers are only sent when ``type`` is `.http`; they are
        /// ignored for SOCKS proxies.
        ///
        /// The `host` and `proxy-authorization` headers are always set by the client
        /// based on the connection target and ``authorization``, and take precedence
        /// over any value provided here.
        public var connectHeaders: HTTPHeaders = [:]

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

        /// Create a HTTP proxy.
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

        /// Create a SOCKSv5 proxy.
        /// - parameter host: The SOCKSv5 proxy address.
        /// - parameter port: The SOCKSv5 proxy port, defaults to 1080.
        /// - parameter name: an optional, human-readable name for this proxy, used for description/debugging purposes only.
        /// - returns: A new instance of `Proxy` configured to connect to a `SOCKSv5` server.
        public static func socksServer(host: String, port: Int = 1080, authorization: HTTPClient.Authorization? = nil, name: String? = nil) -> Proxy {
            var proxy = Proxy(host: host, port: port, type: .socks, authorization: authorization)
            proxy.name = name
            return proxy
        }

        // `HTTPHeaders` is `Equatable` but not `Hashable`, so we cannot rely on the
        // compiler-synthesized conformance and implement `Hashable` manually instead.
        public func hash(into hasher: inout Hasher) {
            hasher.combine(self.host)
            hasher.combine(self.port)
            hasher.combine(self.type)
            hasher.combine(self.authorization)
            hasher.combine(self.internalTlsConfiguration)
            for (name, value) in self.connectHeaders {
                hasher.combine(name)
                hasher.combine(value)
            }
        }

        public static func == (lhs: Proxy, rhs: Proxy) -> Bool {
            lhs.host == rhs.host
                && lhs.port == rhs.port
                && lhs.type == rhs.type
                && lhs.authorization == rhs.authorization
                && lhs.internalTlsConfiguration == rhs.internalTlsConfiguration
                && lhs.connectHeaders == rhs.connectHeaders
        }
    }
}
