//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2020 Apple Inc. and the AsyncHTTPClient project authors
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
import NIOPosix

#if canImport(Network)
import Network
import NIOTransportServices
#endif

extension HTTPClient {
    #if canImport(Network)
    /// A wrapper for `POSIX` errors thrown by `Network.framework`.
    public struct NWPOSIXError: Error, CustomStringConvertible {
        /// POSIX error code (enum)
        public let errorCode: POSIXErrorCode

        /// actual reason, in human readable form
        private let reason: String

        /// Initialise a NWPOSIXError
        /// - Parameters:
        ///   - errorCode: posix error code
        ///   - reason: String describing reason for error
        public init(_ errorCode: POSIXErrorCode, reason: String) {
            self.errorCode = errorCode
            self.reason = reason
        }

        public var description: String { self.reason }
    }

    /// A wrapper for TLS errors thrown by `Network.framework`.
    public struct NWTLSError: Error, CustomStringConvertible {
        /// TLS error status. List of TLS errors can be found in `<Security/SecureTransport.h>`
        public let status: OSStatus

        /// The `Security` status of the certificate trust evaluation that rejected the connection,
        /// e.g. `errSecCertificateExpired`, `errSecHostNameMismatch`, `errSecNotTrusted` or
        /// `errSecCertificateRevoked`.
        ///
        /// `Network.framework` reports every trust failure as `errSSLBadCert`, so ``status`` cannot
        /// tell them apart. `nil` when the handshake failed for a reason other than the certificate
        /// trust evaluation, or when the failure has no `Security` status.
        public let trustEvaluationStatus: OSStatus?

        /// actual reason, in human readable form
        private let reason: String

        /// initialise a NWTLSError
        /// - Parameters:
        ///   - status: TLS status
        ///   - reason: String describing reason for error
        public init(_ status: OSStatus, reason: String) {
            self.init(status, trustEvaluationStatus: nil, reason: reason)
        }

        /// initialise a NWTLSError
        /// - Parameters:
        ///   - status: TLS status
        ///   - trustEvaluationStatus: `Security` status of the failed certificate trust evaluation
        ///   - reason: String describing reason for error
        public init(_ status: OSStatus, trustEvaluationStatus: OSStatus?, reason: String) {
            self.status = status
            self.trustEvaluationStatus = trustEvaluationStatus
            self.reason = reason
        }

        public var description: String {
            guard let trustEvaluationStatus = self.trustEvaluationStatus else { return self.reason }
            return "\(self.reason) (certificate trust evaluation failed with \(trustEvaluationStatus))"
        }
    }
    #endif

    final class NWErrorHandler: ChannelInboundHandler {
        typealias InboundIn = HTTPClientResponsePart

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            context.fireErrorCaught(NWErrorHandler.translateError(error))
        }

        /// - Parameter trustEvaluationStatus: The `Security` status of the certificate trust
        ///   evaluation that rejected this connection attempt, if it was rejected by one.
        static func translateError(_ error: Error, trustEvaluationStatus: OSStatus? = nil) -> Error {
            #if canImport(Network)
            if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
                if let error = error as? NWError {
                    switch error {
                    case .tls(let status):
                        return NWTLSError(
                            status,
                            trustEvaluationStatus: trustEvaluationStatus,
                            reason: String(describing: error)
                        )
                    case .posix(let errorCode):
                        return NWPOSIXError(errorCode, reason: String(describing: error))
                    default:
                        return error
                    }
                }

                // Happy eyeballs reports one error per address it tried, none of them translated,
                // and the addresses that were unreachable or never answered are reported alongside
                // the one that rejected the certificate. A rejected certificate is the actionable
                // failure, so report that instead of the aggregate.
                if let trustEvaluationStatus = trustEvaluationStatus, let error = error as? NIOConnectionError {
                    let tlsStatus = error.connectionErrors.lazy.compactMap { failure -> OSStatus? in
                        guard let nwError = failure.error as? NWError, case .tls(let status) = nwError else {
                            return nil
                        }
                        return status
                    }.first
                    if let tlsStatus = tlsStatus {
                        return NWTLSError(
                            tlsStatus,
                            trustEvaluationStatus: trustEvaluationStatus,
                            reason: String(describing: error)
                        )
                    }
                }
                return error
            } else {
                preconditionFailure("\(self) used on a non-NIOTS Channel")
            }
            #else
            preconditionFailure("\(self) used on a non-NIOTS Channel")
            #endif
        }
    }
}
