import Foundation
import ErrorHandling
import PromiseKit
import PMKFoundation

public class Client {
    private static let authTypes = ["sa", "hsa", "non-sa", "hsa2"]

    public init() {}

    public enum Error: Swift.Error, LocalizedError, Equatable {
        case invalidSession
        case invalidUsernameOrPassword(username: String)
        case invalidPhoneNumberIndex(min: Int, max: Int, given: String?)
        case incorrectSecurityCode
        case unexpectedSignInResponse(statusCode: Int, message: String?)
        case appleIDAndPrivacyAcknowledgementRequired

        public var errorDescription: String? {
            switch self {
            case .invalidSession:
                return "Invalid session."
            case .invalidUsernameOrPassword(let username):
                return "Invalid username and password combination. Attempted to sign in with username \(username)."
            case .invalidPhoneNumberIndex(let min, let max, let given):
                return "Not a valid phone number index. Expecting a whole number between \(min)-\(max), but was given \(given ?? "nothing")."
            case .incorrectSecurityCode:
                return "Incorrect security code."
            case .unexpectedSignInResponse(let statusCode, let message):
                return "Received an unexpected sign-in response. Status code: \(statusCode). Message: \(message ?? "")."
            case .appleIDAndPrivacyAcknowledgementRequired:
                return "You must sign in to https://appstoreconnect.apple.com and acknowledge the Apple ID & Privacy agreement."
            }
        }
    }

    /// Use the olympus session endpoint to see if the existing session is still valid
    public func validateSession() -> Promise<Void> {
        return Current.network.dataTask(with: URLRequest.olympusSession)
        .done { data, response in
            guard
                let jsonObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                jsonObject["provider"] != nil
            else { throw Error.invalidSession }
        }
    }

    public func login(accountName: String, password: String) -> Promise<Void> {
        var serviceKey: String!

        return firstly { () -> Promise<(data: Data, response: URLResponse)> in
            Current.network.dataTask(with: URLRequest.itcServiceKey)
        }
        .then { (data, response) -> Promise<(data: Data, response: URLResponse)> in
            struct ServiceKeyResponse: Decodable {
                let authServiceKey: String
            }

            let response = try catchAndMapError(JSONDecoder().decode(ServiceKeyResponse.self, from: data),
                                                map: { ResponseDecodingError(error: $0, bodyData: data, response: response) })
            serviceKey = response.authServiceKey

            return Current.network.dataTask(with: URLRequest.signIn(serviceKey: serviceKey, accountName: accountName, password: password))
        }
        .then { (data, response) -> Promise<Void> in
            struct SignInResponse: Decodable {
                let authType: String?
                let serviceErrors: [ServiceError]?

                struct ServiceError: Decodable, CustomStringConvertible {
                    let code: String
                    let message: String

                    var description: String {
                        return "\(code): \(message)"
                    }
                }
            }

            let httpResponse = response as! HTTPURLResponse
            let responseBody = try catchAndMapError(JSONDecoder().decode(SignInResponse.self, from: data),
                                                    map: { ResponseDecodingError(error: $0, bodyData: data, response: response) })

            switch httpResponse.statusCode {
            case 200:
                return Current.network.dataTask(with: URLRequest.olympusSession).asVoid()
            case 401:
                throw Error.invalidUsernameOrPassword(username: accountName)
            case 409:
                return self.handleTwoStepOrFactor(data: data, response: response, serviceKey: serviceKey)
            case 412 where Client.authTypes.contains(responseBody.authType ?? ""):
                throw Error.appleIDAndPrivacyAcknowledgementRequired
            default:
                throw Error.unexpectedSignInResponse(statusCode: httpResponse.statusCode,
                                                     message: responseBody.serviceErrors?.map { $0.description }.joined(separator: ", "))
            }
        }
    }

    func handleTwoStepOrFactor(data: Data, response: URLResponse, serviceKey: String) -> Promise<Void> {
        let httpResponse = response as! HTTPURLResponse
        let sessionID = (httpResponse.allHeaderFields["X-Apple-ID-Session-Id"] as! String)
        let scnt = (httpResponse.allHeaderFields["scnt"] as! String)

        return firstly { () -> Promise<AuthOptionsResponse> in
            return Current.network.dataTask(with: URLRequest.authOptions(serviceKey: serviceKey, sessionID: sessionID, scnt: scnt))
                .map { data, response in
                    try catchAndMapError(JSONDecoder().decode(AuthOptionsResponse.self, from: data),
                                         map: { ResponseDecodingError(error: $0, bodyData: data, response: response) })
                }
        }
        .then { authOptions -> Promise<Void> in
            switch authOptions.kind {
            case .twoStep:
                Current.logging.log("Received a response from Apple that indicates this account has two-step authentication enabled. xcodes currently only supports the newer two-factor authentication, though. Please consider upgrading to two-factor authentication, or open an issue on GitHub explaining why this isn't an option for you here: https://github.com/RobotsAndPencils/xcodes/issues/new")
                return Promise.value(())
            case .twoFactor:
                return self.handleTwoFactor(serviceKey: serviceKey, sessionID: sessionID, scnt: scnt, authOptions: authOptions)
            case .unknown:
                Current.logging.log("Received a response from Apple that indicates this account has two-step or two-factor authentication enabled, but xcodes is unsure how to handle this response:")
                String(data: data, encoding: .utf8).map { Current.logging.log($0) }
                return Promise.value(())
            }
        }
    }
    
    func handleTwoFactor(serviceKey: String, sessionID: String, scnt: String, authOptions: AuthOptionsResponse) -> Promise<Void> {
        Current.logging.log("Two-factor authentication is enabled for this account.\n")

        // SMS was sent automatically 
        if authOptions.smsAutomaticallySent {
            return firstly { () throws -> Promise<(data: Data, response: URLResponse)> in
                let code = self.promptForSMSSecurityCode(length: authOptions.securityCode.length, for: authOptions.trustedPhoneNumbers!.first!)
                return Current.network.dataTask(with: try URLRequest.submitSecurityCode(serviceKey: serviceKey, sessionID: sessionID, scnt: scnt, code: code))
                    .validateSecurityCodeResponse()
            }
            .then { (data, response) -> Promise<Void>  in
                self.updateSession(serviceKey: serviceKey, sessionID: sessionID, scnt: scnt)
            }
        // SMS wasn't sent automatically because user needs to choose a phone to send to
        } else if authOptions.canFallBackToSMS {
            return handleWithPhoneNumberSelection(authOptions: authOptions, serviceKey: serviceKey, sessionID: sessionID, scnt: scnt)
        // Code is shown on trusted devices
        } else {
            let code = Current.shell.readLine("""
            Enter "sms" without quotes to exit this prompt and choose a phone number to send an SMS security code to.
            Enter the \(authOptions.securityCode.length) digit code from one of your trusted devices: 
            """) ?? ""
            
            if code == "sms" {
                return handleWithPhoneNumberSelection(authOptions: authOptions, serviceKey: serviceKey, sessionID: sessionID, scnt: scnt)
            }

            return firstly {
                Current.network.dataTask(with: try URLRequest.submitSecurityCode(serviceKey: serviceKey, sessionID: sessionID, scnt: scnt, code: .device(code: code)))
                    .validateSecurityCodeResponse()
                    
            }
            .then { (data, response) -> Promise<Void>  in
                self.updateSession(serviceKey: serviceKey, sessionID: sessionID, scnt: scnt)
            }
        }
    }
    
    func updateSession(serviceKey: String, sessionID: String, scnt: String) -> Promise<Void> {
        return Current.network.dataTask(with: URLRequest.trust(serviceKey: serviceKey, sessionID: sessionID, scnt: scnt))
            .then { (data, response) -> Promise<Void> in
                Current.network.dataTask(with: URLRequest.olympusSession).asVoid()
            }
    }
    
    func selectPhoneNumberInteractively(from trustedPhoneNumbers: [AuthOptionsResponse.TrustedPhoneNumber]) -> Promise<AuthOptionsResponse.TrustedPhoneNumber> {
        return firstly { () throws -> Guarantee<AuthOptionsResponse.TrustedPhoneNumber> in
            Current.logging.log("Trusted phone numbers:")
            trustedPhoneNumbers.enumerated().forEach { (index, phoneNumber) in
                Current.logging.log("\(index + 1): \(phoneNumber.numberWithDialCode)")
            }

            let possibleSelectionNumberString = Current.shell.readLine("Select a trusted phone number to receive a code via SMS: ")
            guard
                let selectionNumberString = possibleSelectionNumberString,
                let selectionNumber = Int(selectionNumberString) ,
                trustedPhoneNumbers.indices.contains(selectionNumber - 1)
            else {
                throw Error.invalidPhoneNumberIndex(min: 1, max: trustedPhoneNumbers.count, given: possibleSelectionNumberString)
            }

            return .value(trustedPhoneNumbers[selectionNumber - 1])
        }
        .recover { error throws -> Promise<AuthOptionsResponse.TrustedPhoneNumber> in
            guard case Error.invalidPhoneNumberIndex = error else { throw error }
            Current.logging.log("\(error.legibleLocalizedDescription)\n")
            return self.selectPhoneNumberInteractively(from: trustedPhoneNumbers)
        }
    }
    
    func promptForSMSSecurityCode(length: Int, for trustedPhoneNumber: AuthOptionsResponse.TrustedPhoneNumber) -> SecurityCode {
        let code = Current.shell.readLine("Enter the \(length) digit code sent to \(trustedPhoneNumber.numberWithDialCode): ") ?? ""
        return .sms(code: code, phoneNumberId: trustedPhoneNumber.id)
    }
    
    func handleWithPhoneNumberSelection(authOptions: AuthOptionsResponse, serviceKey: String, sessionID: String, scnt: String) -> Promise<Void> {
        return firstly {
            selectPhoneNumberInteractively(from: authOptions.trustedPhoneNumbers!)
        }
        .then { trustedPhoneNumber in
            Current.network.dataTask(with: try URLRequest.requestSecurityCode(serviceKey: serviceKey, sessionID: sessionID, scnt: scnt, trustedPhoneID: trustedPhoneNumber.id))
                .map { _ in
                    self.promptForSMSSecurityCode(length: authOptions.securityCode.length, for: trustedPhoneNumber)
                }
        }
        .then { code in
            Current.network.dataTask(with: try URLRequest.submitSecurityCode(serviceKey: serviceKey, sessionID: sessionID, scnt: scnt, code: code))
                .validateSecurityCodeResponse()
        }
        .then { (data, response) -> Promise<Void>  in
            self.updateSession(serviceKey: serviceKey, sessionID: sessionID, scnt: scnt)
        }
    }
}

public extension Promise where T == (data: Data, response: URLResponse) {
    func validateSecurityCodeResponse() -> Promise<T> {
        validate()
            .recover { error -> Promise<(data: Data, response: URLResponse)> in
                switch error {
                case PMKHTTPError.badStatusCode(let code, _, _):
                    if code == 401 {
                        throw Client.Error.incorrectSecurityCode
                    } else {
                        throw error
                    }
                default:
                    throw error
                }
            }
    }
}

struct AuthOptionsResponse: Decodable {
    let trustedPhoneNumbers: [TrustedPhoneNumber]?
    let trustedDevices: [TrustedDevice]?
    let securityCode: SecurityCodeInfo
    let noTrustedDevices: Bool?
    let serviceErrors: [ServiceError]?
    
    var kind: Kind {
        if trustedDevices != nil {
            return .twoStep
        } else if trustedPhoneNumbers != nil {
            return .twoFactor
        } else {
            return .unknown
        }
    }
    
    // One time with a new testing account I had a response where noTrustedDevices was nil, but the account didn't have any trusted devices.
    // This should have been a situation where an SMS security code was sent automatically.
    // This resolved itself either after some time passed, or by signing into appleid.apple.com with the account.
    // Not sure if it's worth explicitly handling this case or if it'll be really rare.
    var canFallBackToSMS: Bool {
        noTrustedDevices == true
    }
    
    var smsAutomaticallySent: Bool {
        trustedPhoneNumbers?.count == 1 && canFallBackToSMS
    }
    
    struct TrustedPhoneNumber: Decodable {
        let id: Int
        let numberWithDialCode: String
    }
    
    struct TrustedDevice: Decodable {
        let id: String
        let name: String
        let modelName: String
    }
    
    struct SecurityCodeInfo: Decodable {
        let length: Int
        let tooManyCodesSent: Bool
        let tooManyCodesValidated: Bool
        let securityCodeLocked: Bool
        let securityCodeCooldown: Bool
    }
    
    enum Kind {
        case twoStep, twoFactor, unknown
    }
}

public struct ServiceError: Decodable, Equatable {
    let code: String
    let message: String
}

enum SecurityCode {
    case device(code: String)
    case sms(code: String, phoneNumberId: Int)
    
    var urlPathComponent: String {
        switch self {
        case .device: return "trusteddevice"
        case .sms: return "phone"
        }
    }
}
