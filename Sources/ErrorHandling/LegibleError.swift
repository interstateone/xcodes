/**
 https://github.com/mxcl/LegibleError, with some changes
 */

import Foundation

extension Error {
    /// - Returns: A fully qualified representation of this error.
    public var legibleDescription: String {
        switch errorType {
        case .swiftError(.enum?), .swiftLocalizedError(_, .enum?):
            return "\(type(of: self)).\(self)"
        case .swiftError(.class?), .swiftLocalizedError(_, .class?):
            //TODO better
            return "\(type(of: self))"
        case .swiftError, .swiftLocalizedError:
            return String(describing: self)
        case let .nsError(nsError, domain, code):
            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                return "\(domain)(\(code), \(underlyingError.domain)(\(underlyingError.code)))"
            } else {
                return "\(domain)(\(code))"
            }
        }
    }

    /// - Returns: A fully qualified, user-visible representation of this error.
    public var legibleLocalizedDescription: String {
        switch errorType {
        case .swiftError:
            return "\(localizedDescription) (\(legibleDescription))"
        case .swiftLocalizedError(let msg, _):
            return msg
        case .nsError(_, "kCLErrorDomain", 0):
            return "The location could not be determined."
            // ^^ Apple don’t provide a localized description for this
        case let .nsError(nsError, _, _):
            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                return underlyingError.legibleLocalizedDescription
            } else {
                return localizedDescription
            }
        }
    }

    private var errorType: ErrorType {
      #if os(Linux)
        let isNSError = self is NSError
      #else
        let foo: Any = self
        let isNSError = String(cString: object_getClassName(self)) != "__SwiftNativeNSError" && foo is NSObject
        // ^^ ∵ otherwise implicit bridging implicitly casts as for other tests
      #endif

        if isNSError {
            let nserr = self as NSError
            return .nsError(nserr, domain: nserr.domain, code: nserr.code)
        } else if let err = self as? LocalizedError, let msg = err.errorDescription {
            return .swiftLocalizedError(msg, Mirror(reflecting: self).displayStyle)
        } else {
            return .swiftError(Mirror(reflecting: self).displayStyle)
        }
    }
}

private enum ErrorType {
    case nsError(NSError, domain: String, code: Int)
    case swiftLocalizedError(String, Mirror.DisplayStyle?)
    case swiftError(Mirror.DisplayStyle?)
}
