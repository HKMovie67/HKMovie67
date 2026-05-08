//
//  HKMovie67App.swift
//  HKMovie67
//
//  Created by Y. Sunny Lai on 3/1/26.
//

import SwiftUI
import SwiftData
import FirebaseCore
import GoogleSignIn // 1. Import GoogleSignIn

// Firebase requires an AppDelegate to configure correctly in SwiftUI
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        FirebaseApp.configure()
        return true
    }
}

@main
struct HKMovie67App: App {
    // Register the app delegate for Firebase setup
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 2. Handle Google Sign-In URL Redirects
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
