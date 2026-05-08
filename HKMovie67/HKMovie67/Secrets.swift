import Foundation

enum Secrets {
    private static let fileName = "Secrets"
    
    static let imgBBApiKey: String = {
        value(for: "4ab209de2c734afe68ca3de458a370bb")
    }()
    
    static let tmdbApiKey: String = {
        value(for: "087fe585100b7b9441c86cc4f4094166")
    }()
    
    static let adminPassword: String = {
        value(for: "admin")
    }()
    
    private static func value(for key: String) -> String {
        guard let path = Bundle.main.path(forResource: fileName, ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let value = dict[key] as? String, !value.isEmpty else {
            fatalError("❌ Secrets.plist missing key '\(key)'. Add it to the plist in your project bundle.")
        }
        return value
    }
}
