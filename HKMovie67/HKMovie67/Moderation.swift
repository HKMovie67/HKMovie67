//
// Moderation.swift
// HKMovie67
//

import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

@Observable
final class BlockedUserManager {
    private let db = Firestore.firestore(database: "ai-studio-c2f1ae4d-bb2b-48e7-876b-c75e5b54a82f")
    private var listener: ListenerRegistration?
    private var authHandle: AuthStateDidChangeListenerHandle?

    var blockedUserIds: Set<String> = []

    init() {
        // Listen for auth changes and start/stop listening accordingly
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self = self else { return }
            if let uid = user?.uid {
                self.startListening(userId: uid)
            } else {
                self.stopListening()
            }
        }
    }

    deinit {
        if let handle = authHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
        stopListening()
    }

    func startListening(userId: String) {
        stopListening()
        listener = db.collection("users")
            .document(userId)
            .collection("blockedUsers")
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self = self else { return }
                var set = Set<String>()
                for doc in snapshot?.documents ?? [] {
                    if let blockedId = doc.data()["blockedUserId"] as? String, !blockedId.isEmpty {
                        set.insert(blockedId)
                    } else {
                        set.insert(doc.documentID)
                    }
                }
                Task { @MainActor in
                    self.blockedUserIds = set
                }
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
        Task { @MainActor in self.blockedUserIds = [] }
    }

    func isBlocked(_ userId: String) -> Bool {
        blockedUserIds.contains(userId)
    }

    func block(_ targetUserId: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = db.collection("users").document(uid).collection("blockedUsers").document(targetUserId)
        let data: [String: Any] = [
            "blockedUserId": targetUserId,
            "createdAt": FieldValue.serverTimestamp()
        ]
        ref.setData(data, merge: true)
    }

    func unblock(_ targetUserId: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = db.collection("users").document(uid).collection("blockedUsers").document(targetUserId)
        ref.delete()
    }
}
