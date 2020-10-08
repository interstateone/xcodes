import Foundation

public struct ResponseDecodingError: LocalizedError {
    let error: Error
    let bodyData: Data
    let response: URLResponse

    public init(error: Error, bodyData: Data, response: URLResponse) {
        self.error = error
        self.bodyData = bodyData
        self.response = response
    }
    
    public var errorDescription: String? {
        """
        Error occurred while decoding response body.
        Error: \(error.legibleLocalizedDescription)
        Response: \(response)
        Body: \(String(data: bodyData, encoding: .utf8) ?? "")
        """
    }
}
