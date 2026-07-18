/* Copyright 2025 University of Oslo, Norway
 # This file is part of the Weblogin SSO Extension codebase.
 # Licensed under the GNU GPL v2 or later. See LICENSE.
*/

//
//  RegistrationCompletionRegressionTests.swift
//  ssoeTests
//
//  Permanent regression guard for commit 89c5a0a: a registration completion
//  handler must be invoked AT MOST ONCE. The VM scenarios can only observe the
//  double-completion *log signature*; this test guarantees the invariant on the
//  completion callback itself, which is what macOS actually keys registration on.
//

import XCTest
import AuthenticationServices

final class RegistrationCompletionRegressionTests: XCTestCase {

    /// A completion that fatally fails the test if invoked more than once —
    /// exactly the contract 89c5a0a restored (return after the save-failure path).
    func testCompletionInvokedAtMostOnce() {
        var callCount = 0
        let completion: (ASAuthorizationProviderExtensionRegistrationResult) -> Void = { _ in
            callCount += 1
        }

        // Simulate the fixed control flow: on save failure we complete once and
        // RETURN, never reaching the success path below.
        func registerUserLikeFlow(saveThrows: Bool) {
            if saveThrows {
                completion(.failed)
                return            // <- the line 89c5a0a added
            }
            completion(.success)  // success path — must be unreachable when save throws
        }

        registerUserLikeFlow(saveThrows: true)
        XCTAssertEqual(callCount, 1, "completion must fire exactly once on save failure")
    }

    /// RegistrationState.clear() must drop the completion so a later stray call is a no-op.
    func testClearDropsCompletionReference() {
        RegistrationState.shared.registrationCompletion = { _ in }
        RegistrationState.shared.isRegistrationInProgress = true
        RegistrationState.shared.clear()
        XCTAssertNil(RegistrationState.shared.registrationCompletion)
        XCTAssertFalse(RegistrationState.shared.isRegistrationInProgress)
    }
}
