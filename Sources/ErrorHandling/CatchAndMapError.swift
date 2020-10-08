import Foundation

public func catchAndMapError<Error2: Error, Result>(_ work: @autoclosure () throws -> Result, map: (Error) -> Error2) rethrows -> Result {
    do {
        return try work()
    } catch {
        throw map(error)
    }
}
