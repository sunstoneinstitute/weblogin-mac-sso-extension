/* Copyright 2025 University of Oslo, Norway
 # This file is part of the Weblogin SSO Extension codebase.
 #
 # The Weblogin SSO Extension is free software; you can redistribute
 # it and/or modify it under the terms of the GNU General Public License
 # as published by the Free Software Foundation;
 # either version 2 of the License, or (at your option) any later version.
 #
 # This software is distributed in the hope that it will be useful,
 # but WITHOUT ANY WARRANTY; without even the implied warranty of
 # MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 # General Public License for more details.
 #
 # You should have received a copy of the GNU General Public License
 # along with this extension; if not, write to the Free Software Foundation,
 # Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307, USA.
*/

//
//  Steupauthentication .swift
//  Weblogin SSO
//
//  Created by Francis Augusto Medeiros-Logeay on 26/11/2025.
//

import WebKit
import LocalAuthentication
import AuthenticationServices



extension AuthenticationViewController: WKScriptMessageHandler {

    /// True when scheme, host and port all match the configured BaseURL.
    /// A nil or zero port means the default port for the scheme.
    func isConfiguredIdPOrigin(scheme: String?, host: String?, port: Int?) -> Bool {
        guard let expected = URLComponents(string: baseURL),
              let expectedScheme = expected.scheme?.lowercased(),
              let expectedHost = expected.host?.lowercased(),
              let scheme = scheme?.lowercased(),
              let host = host?.lowercased() else { return false }

        func effectivePort(_ port: Int?, _ scheme: String) -> Int? {
            if let port = port, port != 0 { return port }
            switch scheme {
            case "https": return 443
            case "http": return 80
            default: return nil
            }
        }

        return scheme == expectedScheme
            && host == expectedHost
            && effectivePort(port, scheme) == effectivePort(expected.port, expectedScheme)
    }

    func isConfiguredIdPOrigin(_ origin: WKSecurityOrigin) -> Bool {
        return isConfiguredIdPOrigin(scheme: origin.protocol, host: origin.host, port: origin.port)
    }

    func isConfiguredIdPURL(_ url: URL?) -> Bool {
        guard let url = url else { return false }
        return isConfiguredIdPOrigin(scheme: url.scheme, host: url.host, port: url.port)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        
        guard message.name == "pssoStepUp" else { return }
        logger.log("webloginlog: Got a JS message.")

        // Only the configured IdP's top-level document in the login web view may ask for a token.
        guard message.frameInfo.isMainFrame,
              message.frameInfo.webView === self.webView,
              isConfiguredIdPOrigin(message.frameInfo.securityOrigin) else {
            logger.error("webloginlog: Ignoring pssoStepUp message from a frame or origin that is not the configured IdP")
            return
        }
        
        guard let body = message.body as? [String: Any] else { return }
        
        if let type = body["type"] as? String, type == "getSignedToken" {
            // One step-up at a time; its answer is tied to this request ID.
            guard pendingStepUpID == nil else {
                logger.error("webloginlog: Ignoring getSignedToken: a step-up request is already pending")
                return
            }
            let requestID = UUID()
            pendingStepUpID = requestID

            handleStepUpRequest{
                error in
                if let error = error {
                    logger.log("webloginlog: Reauthentication failed: \(error)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.sendSignedTokenToJS("none", for: requestID)
                    }
                    return
                }
                
                
                Task { @MainActor in
                    logger.log("webloginlog: Sending signed token to the IdP via javascript")

                    let tokens = self.loginManager?.ssoTokens
                    let tokenType = tokens?[AnyHashable("refresh_token_expires_in")] is Int ? "refresh_token" : "id_token"
                    let clientId = UUID().uuidString

                    // Every exit answers the page; otherwise it waits forever.
                    guard let nonce = try? await self.getNonceFromIdp(clientRequestId: clientId) else {
                        logger.error("webloginlog: Failed to fetch nonce")
                        self.sendSignedTokenToJS("none", for: requestID)
                        return
                    }
                    guard let loginManager = self.loginManager,
                          let token = tokens?[AnyHashable(tokenType)] as? String,
                          let signedToken = self.signToken(token: token, tokenType: tokenType, loginManager: loginManager, nonce: nonce, clientId: clientId) else {
                        logger.error("webloginlog: No \(tokenType) to sign for step-up")
                        self.sendSignedTokenToJS("none", for: requestID)
                        return
                    }
                    self.signedTokenToSend = signedToken
                    self.sendSignedTokenToJS(signedToken, for: requestID)
                }
                    
                
            }
        }
        
        // Answers only through completion, exactly once per path; the caller answers the page.
        func handleStepUpRequest(completion: @escaping ((any Error)?) -> Void) {
            guard let loginManager = loginManager else {
                logger.error("webloginlog: No login manager for step-up")
                completion(ASAuthorizationError(.failed))
                return
            }
            
            // Make sure UI changes happen on main thread
            
            // This is unnecessary as Keycloak will not send a JS message
            // when the authentication method is Password. Nevertheless we keep this here
            // so that we can revaluate this in the future
            
            let forceIdpReauthentication = loginManager.extensionData["ForceIDPReauthentication"] as? Bool ?? false
            
            if forceIdpReauthentication == true {
                if loginManager.authenticationMethod == .password {
                    completion(ASAuthorizationError(.failed))
                    return
                    
                }
                
            }
            
            let forceLocalReauthentication = loginManager.extensionData["ForceLocalReauthentication"] as? Bool ?? false
            
            dumpActivationState("label")
            self.view.isHidden = true
            self.view.window?.makeKeyAndOrderFront(nil)
            self.view.window?.setContentSize(NSMakeSize(10,10))
            
            self.view.window?.isOpaque = false
            self.view.window?.backgroundColor = .clear
            // Make entire view controller contents transparent
            self.view.layer?.backgroundColor = NSColor.clear.cgColor
            self.view.alphaValue = 0.0
            self.view.wantsLayer = true
            self.isMainViewHidden = false
            
            // self.cancelButton.isHidden = false
            self.view.needsLayout = true
            self.webView.isHidden = false
            // Force redraw
            self.view.displayIfNeeded()
            self.view.layoutSubtreeIfNeeded()
            
            
            Task {@MainActor in 
                view.window?.makeKeyAndOrderFront(self)
                if forceLocalReauthentication == false {
                    logger.log("webloginlog: Reauthentication required")
                    loginManager.userNeedsReauthentication{ error in
                        
                        logger.log("webloginlog: Error in reauthentication: \(error?.localizedDescription ?? "no error description")")
                        if error != nil {
                            logger.log("webloginlog: Error with userNeedsReauthentication")
                            DispatchQueue.main.async {
                                completion(error)
                            }
                            return
                        }
                        logger.info( "webloginlog: User successfully reauthenticated. Proceeding with login.")
                        completion(nil)
                    }
                    return
                }
                else {
                    
                    let ctx = LAContext()
                    let localizedReason = String(localized: "authenticate you")
                    ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: localizedReason) {   (success, error) in
                        logger.log("webloginlog: User asked for reauthentication. Success: \(success)")
                        
                        if success != true {
                            logger.log("webloginlog: User didn't approve login. Returning.")
                            // self.authorizationRequest?.cancel()
                            
                            DispatchQueue.main.async {
                                completion(error ?? ASAuthorizationError(.failed))
                            }
                            return
                        }
                        
                        
                        
                        logger.log("webloginlog: Calling userNeedsReauthentication")
                        loginManager.userNeedsReauthentication{ error in
                            
                            
                            if error != nil {
                                logger.log("webloginlog: Error with userNeedsReauthentication")
                                
                                DispatchQueue.main.async {
                                    completion(error)
                                }
                                return
                            }
                            logger.info( "webloginlog: User successfully reauthenticated. Proceeding with login.")
                            completion(nil)
                        }
                        
                        
                    }
                    
                }
            }
        }
        
    }
    
    func sendSignedTokenToJS(_ signedToken: String, for requestID: UUID) {
        DispatchQueue.main.async {
            // Deliver once, and only to the request that asked. A stale call must not
            // clear a newer request's slot.
            guard self.pendingStepUpID == requestID else {
                logger.error("webloginlog: Not delivering step-up result: request \(requestID) is no longer pending")
                return
            }
            self.pendingStepUpID = nil
            guard self.isConfiguredIdPURL(self.webView.url) else {
                logger.error("webloginlog: Not delivering step-up result: the page is not the configured IdP")
                return
            }
            // The token travels as an argument, never as script source.
            self.webView.callAsyncJavaScript("pssoSigned(signedToken);",
                                             arguments: ["signedToken": signedToken],
                                             in: nil,
                                             in: .page) { result in
                if case .failure(let error) = result {
                    logger.error("webloginlog: Error calling pssoSigned: \(error)")
                }
            }
        }
    }
    func logWindowState(_ message: String) {
        DispatchQueue.main.async {
            let key = NSApp.keyWindow
            let main = self.view.window
            logger.log("webloginlog: STATE \(message): keyWindow=\(String(describing: key))  isKey? \(key?.isKeyWindow ?? false)  visible? \(key?.isVisible ?? false)  self.view.window=\(String(describing: main))")
        }
    }
    private func dumpWindowLifecycle(_ label: String) {
        DispatchQueue.main.async {
            let now = ISO8601DateFormatter().string(from: Date())
            let frontApp = NSWorkspace.shared.frontmostApplication
            let frontBundle = frontApp?.bundleIdentifier ?? "nil"
            let keyWin = NSApp.keyWindow
            let mainWin = self.view.window
            logger.log("webloginlog: WL \(now) \(label): frontApp=\(frontBundle) frontAppName=\(frontApp?.localizedName ?? "nil") keyWindow=\(String(describing: keyWin)) isKey=\(keyWin?.isKeyWindow ?? false) keyVisible=\(keyWin?.isVisible ?? false) selfWindow=\(String(describing: mainWin)) selfVisible=\(mainWin?.isVisible ?? false) selfIsKey=\(mainWin?.isKeyWindow ?? false)")
        }
    }
    // Call this once in viewDidLoad() to start logging
     func enableWindowLifecycleLogging() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            if let w = note.object as? NSWindow {
                logger.log("webloginlog: WL-NOTIF: didBecomeKey -> \(w) visible:\(w.isVisible) alpha:\(w.alphaValue)")
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { note in
            if let w = note.object as? NSWindow {
                logger.log("webloginlog: WL-NOTIF: didResignKey -> \(w) visible:\(w.isVisible) alpha:\(w.alphaValue)")
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { note in
            if let w = note.object as? NSWindow {
                logger.log("webloginlog: didBecomeMain -> \(w) visible:\(w.isVisible) alpha:\(w.alphaValue)")
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignMainNotification, object: nil, queue: .main
        ) { note in
            if let w = note.object as? NSWindow {
                logger.debug("webloginlog: WL-NOTIF: didResignMain -> \(w) visible:\(w.isVisible) alpha:\(w.alphaValue)")
            }
        }
    }

    // Call this helper to dump state whenever you want
    // Called on the main thread, and logs synchronously so the state it reports
    // is the state at the call site rather than at the end of the current turn.
    private func dumpActivationState(_ label: String) {
        let now = ISO8601DateFormatter().string(from: Date())
        let front = NSWorkspace.shared.frontmostApplication
        let key = NSApp.keyWindow
        let main = NSApp.mainWindow
        let selfWin = self.view.window
        logger.debug("webloginlog: WL-STATE \(now) \(label): appIsActive=\(NSApp.isActive) frontApp=\(front?.bundleIdentifier ?? "nil") frontName=\(front?.localizedName ?? "nil") keyWindow=\(String(describing: key)) keyIsKey=\(key?.isKeyWindow ?? false) mainWindow=\(String(describing: main)) selfWindow=\(String(describing: selfWin)) selfIsVisible=\(selfWin?.isVisible ?? false) selfIsKey=\(selfWin?.isKeyWindow ?? false)")
    }

    
    
}
