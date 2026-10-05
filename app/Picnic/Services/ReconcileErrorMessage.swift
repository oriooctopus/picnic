import Foundation

/// One plain sentence for any error the Clean up Google flow can hit, so the
/// screen never shows `Error Domain=NSURLErrorDomain Code=-1009 ...`.
enum ReconcileErrorMessage {
    static func plain(_ error: Error) -> String {
        if error is URLError {
            return "Can't reach the Picnic server. Check that this phone is online and on Tailscale."
        }
        if case MirrorClientError.badStatus(let code) = error {
            switch code {
            case 401, 403: return "The Picnic server refused this app's access token."
            case 500...599: return "The Picnic server hit an error (HTTP \(code)); try again in a minute."
            default: return "The Picnic server refused the request (HTTP \(code))."
            }
        }
        if error is DecodingError {
            return "The Picnic server sent a reply this app could not read."
        }
        if let mismatch = error as? ReconcilePhoneMismatch {
            return mismatch.description
        }
        let ns = error as NSError
        if ns.domain == "PHPhotosErrorDomain" && ns.code == 3072 {
            return "The phone deletion was cancelled."
        }
        return "Something went wrong with Clean up Google."
    }
}
