//
//  EventLoopFuture+Extension.swift
//  async-http-client
//
//  Created by Aviad Segev on 22/05/2024.
//

import NIOCore
import NIOPosix

extension EventLoopFuture {
    static func firstSuccess<T: Sendable>(of futures: [EventLoopFuture<T>], on eventLoop: EventLoop, predicate: @escaping (T) -> Bool) -> EventLoopFuture<T> {
        let promise = eventLoop.makePromise(of: T.self)
        var success = false
        var failureCount = 0
        
        for future in futures {
            future.hop(to: eventLoop).assumeIsolated().whenComplete { result in
                switch result {
                case .success(let value):
                    if !success && predicate(value) {
                        success = true
                        promise.succeed(value)
                    }
                case .failure(let error):
                    failureCount += 1
                    if failureCount == futures.count {
                        promise.fail(error)
                    }
                }
            }
        }
        
        return promise.futureResult
    }
}
