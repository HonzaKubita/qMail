import Foundation

public enum MailError: Error, LocalizedError, Sendable, Equatable {
    case connectionClosed
    case timeout
    case protocolError(String)
    case authenticationFailed(String)
    case commandFailed(String)
    case invalidConfiguration(String)
    case oauth(String)
    /// The saved OAuth grant was expired or revoked; the user has to sign in again.
    case signInRequired
    /// Sign-in succeeded but the mail permission was left unticked on the consent screen.
    case mailAccessNotGranted

    public var errorDescription: String? {
        switch self {
        case .connectionClosed: "The server closed the connection."
        case .timeout: "The server took too long to respond."
        case .protocolError(let message): "Unexpected server response: \(message)"
        case .authenticationFailed(let message): "Sign-in failed. \(message)"
        case .commandFailed(let message): message
        case .invalidConfiguration(let message): message
        case .oauth(let message): message
        case .signInRequired: "Your sign-in has expired. Sign in again to keep receiving mail."
        case .mailAccessNotGranted:
            "You signed in, but qMail wasn't allowed to access your mail. Sign in again and tick the box that lets qMail read, compose and send your email."
        }
    }

    /// Errors after which the connection is unusable and a fresh one should be opened.
    public static func isConnectionLevel(_ error: Error) -> Bool {
        if let mailError = error as? MailError {
            switch mailError {
            case .connectionClosed, .timeout: return true
            default: return false
            }
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain || nsError.domain == NSPOSIXErrorDomain
    }
}
