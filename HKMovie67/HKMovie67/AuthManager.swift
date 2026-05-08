//
//  AuthManager.swift
//  HKMovie67
//

import Foundation
import Observation
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn
import AuthenticationServices
import CryptoKit
import UIKit

// MARK: - ImgBB API Models
struct ImgBBResponse: Codable {
    struct Data: Codable {
        let url: String
    }
    let data: Data
}

@Observable
final class AuthManager {
    var user: FirebaseAuth.User? = nil {
        didSet {
            currentDisplayName = user?.displayName ?? user?.email?.components(separatedBy: "@").first ?? ""
            currentUserPhoto = user?.photoURL?.absoluteString ?? ""
        }
    }
    var isLoading: Bool = false
    var errorMessage: String? = nil

    // Profile state synced with Firestore/Auth
    var currentDisplayName: String = ""
    var currentUserPhoto: String = ""

    // Named Firestore database instance
    private let db = Firestore.firestore(database: "ai-studio-c2f1ae4d-bb2b-48e7-876b-c75e5b54a82f")

    // Nonce held between Apple Sign In request and completion callbacks
    private var currentAppleNonce: String?
    
    // Retained during async Apple re-auth flow (for account deletion)
    private var appleReAuthDelegate: AppleReAuthDelegate?

    init() {
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.user = user
        }
    }

    var isSignedIn: Bool { user != nil }
    var displayEmail: String { user?.email ?? "" }
    
    /// The list of Firebase provider IDs the current user signed in with.
    /// Useful for branching account-deletion flows.
    var providerIDs: [String] {
        user?.providerData.map(\.providerID) ?? []
    }

    // MARK: - Email Register
    func register(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            try await ensureUserDocument(for: result.user)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Email Sign In
    func signIn(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            try await ensureUserDocument(for: result.user)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Apple Sign In
    
    @MainActor
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString()
        currentAppleNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
    }
    
    @MainActor
    func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        switch result {
        case .failure(let error):
            if let asError = error as? ASAuthorizationError, asError.code == .canceled {
                return
            }
            errorMessage = error.localizedDescription
            
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Invalid Apple credential."
                return
            }
            guard let nonce = currentAppleNonce else {
                errorMessage = "Apple Sign In session expired. Please try again."
                return
            }
            guard let appleIDToken = appleIDCredential.identityToken,
                  let idTokenString = String(data: appleIDToken, encoding: .utf8) else {
                errorMessage = "Unable to read Apple identity token."
                return
            }
            
            let credential = OAuthProvider.appleCredential(
                withIDToken: idTokenString,
                rawNonce: nonce,
                fullName: appleIDCredential.fullName
            )
            
            do {
                let authResult = try await Auth.auth().signIn(with: credential)
                
                if let fullName = appleIDCredential.fullName {
                    let formatter = PersonNameComponentsFormatter()
                    let display = formatter.string(from: fullName).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !display.isEmpty, (authResult.user.displayName ?? "").isEmpty {
                        let change = authResult.user.createProfileChangeRequest()
                        change.displayName = display
                        try? await change.commitChanges()
                    }
                }
                
                try await ensureUserDocument(for: authResult.user)
                
                await MainActor.run {
                    self.user = Auth.auth().currentUser
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            
            currentAppleNonce = nil
        }
    }

    // MARK: - Google Sign In
    @MainActor
    func signInWithGoogle() async {
        isLoading = true
        errorMessage = nil
        
        do {
            guard let clientID = FirebaseApp.app()?.options.clientID else {
                errorMessage = "Missing Firebase client ID"
                isLoading = false
                return
            }

            let config = GIDConfiguration(clientID: clientID)
            GIDSignIn.sharedInstance.configuration = config

            guard let presentingViewController = topViewController() else {
                errorMessage = "無法開啟登入視窗"
                isLoading = false
                return
            }

            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController)

            guard let idToken = result.user.idToken?.tokenString else {
                throw URLError(.badServerResponse)
            }

            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )

            let authResult = try await Auth.auth().signIn(with: credential)
            try await ensureUserDocument(for: authResult.user)
        } catch {
            print("Google Sign In Error: \(error)")
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }

    // MARK: - Profile Management
    func updateProfile(name: String, photo: String) async {
        guard let uid = user?.uid else { return }
        isLoading = true
        do {
            try await db.collection("users").document(uid).updateData([
                "displayName": name,
                "userPhoto": photo
            ])
            
            let changeRequest = user?.createProfileChangeRequest()
            changeRequest?.displayName = name
            changeRequest?.photoURL = URL(string: photo)
            try await changeRequest?.commitChanges()
            
            await MainActor.run {
                self.currentDisplayName = name
                self.currentUserPhoto = photo
                self.user = Auth.auth().currentUser
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
    
    // MARK: - Image Upload (imgBB)
    func uploadToImgBB(data: Data) async throws -> String {
        let apiKey = "4ab209de2c734afe68ca3de458a370bb"
        guard let url = URL(string: "https://api.imgbb.com/1/upload?key=\(apiKey)") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"avatar.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "ImgBB", code: 0, userInfo: [NSLocalizedDescriptionKey: "Upload failed with status \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
        }
        
        let result = try JSONDecoder().decode(ImgBBResponse.self, from: responseData)
        return result.data.url
    }

    // MARK: - Sign Out
    func signOut() {
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
        currentDisplayName = ""
        currentUserPhoto = ""
    }

    // MARK: - Reset Password
    func resetPassword(email: String) async {
        isLoading = true
        errorMessage = nil
        do {
            try await Auth.auth().sendPasswordReset(withEmail: email)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
    
    // MARK: - Account Deletion (App Store Guideline 5.1.1(v))
    
    /// Deletes the currently signed-in user's Firebase account + Firestore data.
    /// Handles provider-specific re-authentication & (for Apple) token revocation.
    /// - Parameter emailPassword: required if the user only has the password provider.
    /// - Returns: `true` on success. On failure, inspect `errorMessage`.
    @MainActor
    @discardableResult
    func deleteAccount(emailPassword: String? = nil) async -> Bool {
        guard let user = Auth.auth().currentUser else { return false }
        let uid = user.uid
        
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        let providers = Set(providerIDs)
        
        do {
            // 1. Provider-specific re-auth (and token revocation for Apple).
            //    Apple takes priority because Apple MANDATES revokeToken.
            if providers.contains("apple.com") {
                try await reauthenticateWithAppleAndRevoke(user: user)
            } else if providers.contains("google.com") {
                try await reauthenticateWithGoogle(user: user)
            } else if providers.contains("password") {
                guard let pwd = emailPassword, !pwd.isEmpty else {
                    throw NSError(
                        domain: "Auth",
                        code: 1001,
                        userInfo: [NSLocalizedDescriptionKey: "Password is required to delete this account."]
                    )
                }
                try await reauthenticateWithPassword(user: user, password: pwd)
            }
            
            // 2. Best-effort Firestore cleanup for data we own.
            await deleteFirestoreUserData(uid: uid)
            
            // 3. Delete the Firebase Auth account. Firebase will automatically sign out.
            try await user.delete()
            
            // 4. Local cleanup
            GIDSignIn.sharedInstance.signOut()
            self.currentDisplayName = ""
            self.currentUserPhoto = ""
            
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
    
    @MainActor
    private func reauthenticateWithPassword(user: FirebaseAuth.User, password: String) async throws {
        guard let email = user.email else {
            throw NSError(domain: "Auth", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing email for re-authentication."])
        }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        try await user.reauthenticate(with: credential)
    }
    
    @MainActor
    private func reauthenticateWithGoogle(user: FirebaseAuth.User) async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw NSError(domain: "Auth", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing Firebase client ID."])
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        
        guard let presenter = topViewController() else {
            throw NSError(domain: "Auth", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unable to present sign-in UI."])
        }
        
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else {
            throw URLError(.badServerResponse)
        }
        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
        try await user.reauthenticate(with: credential)
    }
    
    @MainActor
    private func reauthenticateWithAppleAndRevoke(user: FirebaseAuth.User) async throws {
        let nonce = randomNonceString()
        let hashedNonce = sha256(nonce)
        
        let credential: ASAuthorizationAppleIDCredential = try await withCheckedThrowingContinuation { continuation in
            let delegate = AppleReAuthDelegate(continuation: continuation)
            self.appleReAuthDelegate = delegate
            
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = hashedNonce
            
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = delegate
            controller.presentationContextProvider = delegate
            controller.performRequests()
        }
        
        self.appleReAuthDelegate = nil
        
        guard let idTokenData = credential.identityToken,
              let idTokenString = String(data: idTokenData, encoding: .utf8) else {
            throw NSError(domain: "Auth", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing Apple identity token."])
        }
        
        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: nonce,
            fullName: credential.fullName
        )
        
        // 1. Re-auth (satisfies "recent login" requirement for delete)
        try await user.reauthenticate(with: firebaseCredential)
        
        // 2. Revoke the Apple refresh token (REQUIRED by Apple Guideline 5.1.1(v))
        if let codeData = credential.authorizationCode,
           let codeString = String(data: codeData, encoding: .utf8),
           !codeString.isEmpty {
            do {
                try await Auth.auth().revokeToken(withAuthorizationCode: codeString)
            } catch {
                // Revocation failing should not block account deletion.
                // Log it for diagnostics but continue.
                print("⚠️ Apple revokeToken failed: \(error.localizedDescription)")
            }
        }
    }
    
    private func deleteFirestoreUserData(uid: String) async {
        let userRef = db.collection("users").document(uid)
        
        // Known subcollections we own. Add more here if the schema grows.
        let subcollections = ["watched_v2", "movieStates"]
        
        for sub in subcollections {
            do {
                let snapshot = try await userRef.collection(sub).getDocuments()
                for doc in snapshot.documents {
                    try? await doc.reference.delete()
                }
            } catch {
                print("⚠️ Failed to clean subcollection \(sub): \(error.localizedDescription)")
            }
        }
        
        // Top-level user doc
        try? await userRef.delete()
        
        // NOTE: Reviews/comments/likes under `reviews_v2/*` still reference this
        // userId. For full GDPR/privacy compliance, add a Cloud Function
        // triggered on user deletion that anonymises or removes those records.
    }

    // MARK: - Firestore Sync: Load
    func loadUserData(into watched: WatchedManager, premium: PremiumManager) async {
        guard let uid = user?.uid else { return }
        do {
            let doc = try await db.collection("users").document(uid).getDocument()
            guard let data = doc.data() else { return }

            await MainActor.run {
                if let w = data["watchedMovieTitles"] as? [String] {
                    watched.watchedMovieTitles = Set(w)
                } else if let wLegacy = data["watchedMovieIDs"] as? [String] {
                    watched.watchedMovieTitles = Set(wLegacy)
                }
                
                if let s = data["skippedMovieTitles"] as? [String] {
                    watched.skippedMovieTitles = Set(s)
                } else if let sLegacy = data["skippedMovieIDs"] as? [String] {
                    watched.skippedMovieTitles = Set(sLegacy)
                }
                
                if let sub = data["isPremiumSubscribed"] as? Bool {
                    premium.isSubscribed = sub
                }
                if let trial = data["trialStartTimestamp"] as? Double {
                    premium.trialStartTimestamp = trial
                }
                premium.selectedFreeOptionId = data["selectedFreeOptionId"] as? String
                
                if let name = data["displayName"] as? String, !name.isEmpty {
                    self.currentDisplayName = name
                }
                if let photo = data["userPhoto"] as? String {
                    self.currentUserPhoto = photo
                }
            }
        } catch {
            print("Firestore load error: \(error.localizedDescription)")
        }
    }

    // MARK: - Firestore Sync: Save Watched
    func saveWatched(watched: WatchedManager) {
        guard let uid = user?.uid else { return }
        db.collection("users").document(uid).updateData([
            "watchedMovieTitles": Array(watched.watchedMovieTitles),
            "skippedMovieTitles": Array(watched.skippedMovieTitles)
        ])
    }

    // MARK: - Firestore Sync: Save Premium
    func savePremium(premium: PremiumManager) {
        guard let uid = user?.uid else { return }
        var data: [String: Any] = [
            "isPremiumSubscribed": premium.isSubscribed,
            "trialStartTimestamp": premium.trialStartTimestamp
        ]
        if let freeID = premium.selectedFreeOptionId {
            data["selectedFreeOptionId"] = freeID
        } else {
            data["selectedFreeOptionId"] = NSNull()
        }
        db.collection("users").document(uid).updateData(data)
    }

    // MARK: - Helpers
    private func ensureUserDocument(for user: FirebaseAuth.User) async throws {
        let docRef = db.collection("users").document(user.uid)
        let snapshot = try await docRef.getDocument()

        if !snapshot.exists {
            try await docRef.setData([
                "watchedMovieTitles": [String](),
                "skippedMovieTitles": [String](),
                "isPremiumSubscribed": false,
                "trialStartTimestamp": 0.0,
                "selectedFreeOptionId": NSNull(),
                "displayName": user.displayName ?? user.email?.components(separatedBy: "@").first ?? "User",
                "userPhoto": user.photoURL?.absoluteString ?? ""
            ])
        }
    }

    @MainActor
    private func topViewController() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return nil
        }
        return topViewController(from: rootViewController)
    }

    private func topViewController(from root: UIViewController) -> UIViewController {
        if let presented = root.presentedViewController {
            return topViewController(from: presented)
        }
        if let nav = root as? UINavigationController, let visible = nav.visibleViewController {
            return topViewController(from: visible)
        }
        if let tab = root as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(from: selected)
        }
        return root
    }
    
    // MARK: - Apple Sign In Cryptography Helpers
    
    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes)
        if status != errSecSuccess {
            fatalError("Unable to generate Apple Sign In nonce. SecRandomCopyBytes failed with OSStatus \(status)")
        }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }
    
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Apple Re-Auth Delegate (for account deletion)

private final class AppleReAuthDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>
    private var didResume = false
    
    init(continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>) {
        self.continuation = continuation
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard !didResume else { return }
        didResume = true
        
        if let cred = authorization.credential as? ASAuthorizationAppleIDCredential {
            continuation.resume(returning: cred)
        } else {
            continuation.resume(throwing: NSError(
                domain: "Auth",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Apple credential."]
            ))
        }
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard !didResume else { return }
        didResume = true
        continuation.resume(throwing: error)
    }
    
    @MainActor
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
    }
}
