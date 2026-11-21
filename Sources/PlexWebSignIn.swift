import Foundation
#if os(iOS)
import AuthenticationServices
import UIKit
#endif

/// Shows Plex's approval page. On iPhone it opens in Apple's web sign-in sheet (ASWebAuthenticationSession),
/// which shares Safari's Plex sign-in and keeps the app in the foreground, so the app keeps checking with
/// HolyArrs while you approve and closes the sheet itself once you have. Plex then sends the page on to
/// HolyArrs' own site rather than back to the app, so the sheet never finishes on its own: the app closes it.
/// On Apple TV there is no browser; the sign-in screen shows a QR code instead.
@MainActor
enum PlexWebSignIn {
    #if os(iOS)
    private static var session: ASWebAuthenticationSession?
    private static let anchor = Anchor()

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
    #endif

    static func open(_ url: URL) {
        #if os(iOS)
        close()
        // The callback scheme is never reached (Plex forwards to HolyArrs' site); the app closes the sheet.
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "holyarrs-signin") { _, _ in
            session = nil
        }
        s.presentationContextProvider = anchor
        s.prefersEphemeralWebBrowserSession = false  // use Safari's Plex sign-in
        if s.start() { session = s }
        #endif
    }

    static func close() {
        #if os(iOS)
        session?.cancel()
        session = nil
        #endif
    }

    /// Connection problems worth retrying rather than reporting.
    nonisolated static func isTransient(_ e: URLError) -> Bool {
        [.networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
         .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .backgroundSessionWasDisconnected]
            .contains(e.code)
    }
}
