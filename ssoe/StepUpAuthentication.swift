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



extension AuthenticationViewController: WKScriptMessageHandler {

    /// True when scheme, host and port all match the configured BaseURL.
    /// A nil or zero port means the default port for the scheme. Compares origins
    /// rather than string prefixes, so idp.example.org.evil.net does not match.
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

    func isConfiguredIdPURL(_ url: URL?) -> Bool {
        guard let url = url else { return false }
        return isConfiguredIdPOrigin(scheme: url.scheme, host: url.host, port: url.port)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        
        guard message.name == "pssoStepUp" else { return }
        logger.log("webloginlog: Got a JS message.")
        
        guard let body = message.body as? [String: Any] else { return }
        
        if let type = body["type"] as? String, type == "getSignedToken" {

            
            
            // Kept out of the condition above on purpose: when the page sends no
            // challenge token it is still waiting for pssoSigned, so this has to be
            // answered and logged rather than silently skipped.
            guard let challenge = body["challenge"] as? String else {
                logger.error("webloginlog: getSignedToken with no challenge token in the message body")
                sendSignedTokenToJS("none")
                return
            }

            Task {
                guard await verifyStepUpJWT(stepupToken: challenge, localChallenge: self.reauthChallenge, loginManager: loginManager) else {
                    logger.error("webloginlog: step-up assertion failed verification")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.sendSignedTokenToJS( "none");
                    }
                    return                           // fail closed, no prompt
                }
            
            
                handleStepUpRequest{
                    error in
                    if let error = error {
                        logger.log("webloginlog: Reauthentication failed: \(error)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            self.sendSignedTokenToJS( "none");
                        }
                        return
                    }
                    
                    
                    Task { @MainActor in
                        logger.log("webloginlog: Sending signed token to the IdP via javascript")
                        
                        let tokens = self.loginManager?.ssoTokens
                        var tokenType = "";
                        if let value = tokens?[AnyHashable("refresh_token_expires_in")] as? Int {
                            tokenType = "refresh_token"
                            
                        }else {
                            tokenType = "id_token"
                        }
                        let clientId = UUID().uuidString
                        
                        // Every exit below answers the page. A bare return here leaves
                        // the IdP waiting for pssoSigned forever and the login wedged.
                        guard let nonce = try? await self.getNonceFromIdp(clientRequestId: clientId) else {
                            logger.error("webloginlog: Failed to fetch nonce")
                            self.sendSignedTokenToJS("none")
                            return

                        }

                        guard let loginManager = self.loginManager,
                              let token = tokens?[AnyHashable(tokenType)] as? String,
                              let signedToken = self.signToken(token: token, tokenType: tokenType, loginManager: loginManager, nonce: nonce, clientId: clientId) else {
                            logger.error("webloginlog: No \(tokenType) to sign for step-up")
                            self.sendSignedTokenToJS("none")
                            return
                        }
                        self.signedTokenToSend = signedToken
                        self.sendSignedTokenToJS(signedToken)
                    }
                    
                }
            }
        }
        
        func handleStepUpRequest(completion: @escaping ((any Error)?) -> Void) {
            // Perform the platform SSO reauthentication logic...
            // Then produce your new signed token.
            
            // Make sure UI changes happen on main thread
            
            // This is unnecessary as Keycloak will not send a JS message
            // when the authentication method is Password. Nevertheless we keep this here
            // so that we can revaluate this in the future
            
            let forceIdpReauthentication = loginManager?.extensionData["ForceIDPReauthentication"] as? Bool ?? false
            
            if forceIdpReauthentication == true {
                if loginManager?.authenticationMethod == .password {
                    self.sendSignedTokenToJS("none")
                    return
                    
                }
                
            }
            
            let forceLocalReauthentication = loginManager?.extensionData["ForceLocalReauthentication"] as? Bool ?? false
            
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
                    self.loginManager?.userNeedsReauthentication{ error in
                        
                        if error != nil {
                            logger.log("webloginlog: Error with userNeedsReauthentication: \(error?.localizedDescription ?? "no error description")")
                            DispatchQueue.main.async {
                                self.sendSignedTokenToJS("none")
                                completion(error)
                                    //return
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
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                
                                self.sendSignedTokenToJS( "none");
                                
                            }
                            return
                        }
                        
                        
                        
                        logger.log("webloginlog: Calling userNeedsReauthentication")
                        self.loginManager?.userNeedsReauthentication{ error in
                            
                            
                            if error != nil {
                                logger.log("webloginlog: Error with userNeedsReauthentication")
                                
                                DispatchQueue.main.async {
                                    
                                    
                                    self.sendSignedTokenToJS("none")
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
    
    func sendSignedTokenToJS(_ signedToken: String) {
        // NOT escaped, despite what this comment used to claim. Safe only because a
        // signed envelope is base64url and dots. If anything else can ever reach this,
        // switch to callAsyncJavaScript and pass the token as a bound argument.
        let js = "pssoSigned('\(signedToken)');"

        DispatchQueue.main.async {
            // Reauthentication takes seconds, and the web view can navigate during that
            // window. The step-up request was verified, but the answer must not land in
            // whatever document happens to be current now: check the page at delivery.
            guard self.isConfiguredIdPURL(self.webView.url) else {
                logger.error("webloginlog: Not delivering step-up result: the page is no longer the configured IdP")
                return
            }
            self.webView.evaluateJavaScript(js) { _, error in
                if let error = error {
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
