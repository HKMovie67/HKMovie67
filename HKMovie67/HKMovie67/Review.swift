//
//  Review.swift
//  HKMovie67
//

import Foundation
import Observation
import SwiftUI
import FirebaseAuth
import FirebaseFirestore

enum ReviewVoteKind: Int, Codable, Sendable {
    case none = 0
    case up = 1
    case down = -1
}

struct ReviewReply: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var chineseTitle: String
    var reviewId: String
    var userId: String
    var userName: String
    var userPhoto: String?
    var content: String
    var createdAt: Date
    var updatedAt: Date?
    var upvoteCount: Int
    var downvoteCount: Int
    var userVote: ReviewVoteKind = .none
    
    var displayUserName: String {
        userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Anonymous" : userName
    }
}

struct Review: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var chineseTitle: String
    var userId: String
    var userName: String
    var userPhoto: String?
    var content: String
    var rating: Double
    var createdAt: Date
    var updatedAt: Date?
    var upvoteCount: Int
    var downvoteCount: Int
    var userVote: ReviewVoteKind = .none
    var replies: [ReviewReply] = []
    
    var displayUserName: String {
        userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Anonymous" : userName
    }
    
    var displayRating: Double {
        min(max(rating, 1), 5)
    }
}

@Observable
final class ReviewManager {
    var reviews: [Review] = []
    var isFetching = false
    
    var reviewCount: Int { reviews.count }
    
    var averageRating: Double {
        guard !reviews.isEmpty else { return 0 }
        let total = reviews.reduce(0.0) { $0 + $1.displayRating }
        return total / Double(reviews.count)
    }
    
    private let db = Firestore.firestore(database: "ai-studio-c2f1ae4d-bb2b-48e7-876b-c75e5b54a82f")
    private var commentListener: ListenerRegistration?
    private var ratingListener: ListenerRegistration?
    private var replyListeners: [String: ListenerRegistration] = [:]
    
    private var currentChineseTitle: String?
    private var rawComments: [Review] = []
    private var userRatings: [String: Double] = [:]
    
    func startListening(for chineseTitle: String) {
        stopListening()
        
        let cleanTitle = chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        currentChineseTitle = cleanTitle
        
        Task { @MainActor in
            self.isFetching = true
        }
        
        // 1. Listen to the user's specific star ratings inside `reviews_v2/{chineseTitle}/reviews`
        ratingListener = db.collection("reviews_v2")
            .document(cleanTitle)
            .collection("reviews")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                var newRatings: [String: Double] = [:]
                
                for doc in snapshot?.documents ?? [] {
                    if let userId = doc.data()["userId"] as? String,
                       let rating = doc.data()["rating"] as? Double {
                        newRatings[userId] = rating
                    } else if let rating = doc.data()["rating"] as? Double {
                        // Fallback to reading the doc ID if the schema forgot the internal userId prop
                        newRatings[doc.documentID] = rating
                    }
                }
                
                Task { @MainActor in
                    self.userRatings = newRatings
                    self.publishReviews()
                }
            }
        
        // 2. Listen to the written discussions inside `reviews_v2/{chineseTitle}/comments`
        commentListener = commentsCollection(chineseTitle: cleanTitle)
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                
                if let error {
                    print("Review listener error: \(error.localizedDescription)")
                    Task { @MainActor in
                        self.isFetching = false
                    }
                    return
                }
                
                let documents = snapshot?.documents ?? []
                let reviewIDs = Set(documents.map(\.documentID))
                self.syncReplyListeners(chineseTitle: cleanTitle, reviewIDs: reviewIDs)
                
                Task {
                    let uid = Auth.auth().currentUser?.uid
                    var loadedReviews: [Review] = []
                    
                    for document in documents {
                        var review = self.review(from: document, chineseTitle: cleanTitle)
                        
                        if let uid {
                            review.userVote = await self.fetchVoteKind(
                                at: self.reviewVoteDocument(
                                    chineseTitle: cleanTitle,
                                    reviewId: review.id,
                                    userId: uid
                                )
                            )
                        }
                        
                        review.replies = await self.fetchReplies(chineseTitle: cleanTitle, reviewId: review.id)
                        loadedReviews.append(review)
                    }
                    
                    await MainActor.run {
                        self.rawComments = loadedReviews
                        self.publishReviews()
                    }
                }
            }
    }
    
    func stopListening() {
        commentListener?.remove()
        commentListener = nil
        
        ratingListener?.remove()
        ratingListener = nil
        
        for listener in replyListeners.values {
            listener.remove()
        }
        replyListeners.removeAll()
        currentChineseTitle = nil
        rawComments = []
        userRatings = [:]
        
        Task { @MainActor in
            self.reviews = []
            self.isFetching = false
        }
    }
    
    // Smoothly combines separate ratings and comments from the web structure
    @MainActor
    private func publishReviews() {
        var combined = self.rawComments
        for i in 0..<combined.count {
            // Apply the standalone rating if the user provided one
            if let fetchedRating = self.userRatings[combined[i].userId] {
                combined[i].rating = fetchedRating
            }
        }
        self.reviews = combined
        self.isFetching = false
    }
    
    func upsertReview(chineseTitle: String, content: String, rating: Double = 5.0) async throws {
        guard let user = Auth.auth().currentUser else {
            throw NSError(
                domain: "Auth",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "User not logged in"]
            )
        }
        
        let cleanTitle = chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRating = min(max(rating, 1), 5)
        
        guard !trimmedContent.isEmpty else {
            throw NSError(
                domain: "Review",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Review content cannot be empty"]
            )
        }
        
        let baseDocRef = db.collection("reviews_v2").document(cleanTitle)
        
        // 1. Write the explicit Star Rating to `/reviews/{userId}`
        let ratingData: [String: Any] = [
            "userId": user.uid,
            "rating": normalizedRating,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        try await baseDocRef.collection("reviews").document(user.uid).setData(ratingData, merge: true)
        
        // 2. Write the text Comment to `/comments/{commentId}`
        let commentsRef = baseDocRef.collection("comments")
        let existing = try await commentsRef
            .whereField("userId", isEqualTo: user.uid)
            .limit(to: 1)
            .getDocuments()
        
        let baseData: [String: Any] = [
            "chineseTitle": cleanTitle,
            "userId": user.uid,
            "userName": user.displayName ?? user.email?.components(separatedBy: "@").first ?? "Anonymous",
            "userPhoto": user.photoURL?.absoluteString ?? "",
            "content": trimmedContent,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        
        if let existingDoc = existing.documents.first {
            try await commentsRef.document(existingDoc.documentID).setData(baseData, merge: true)
        } else {
            var newData = baseData
            newData["createdAt"] = FieldValue.serverTimestamp()
            newData["upvoteCount"] = 0
            newData["downvoteCount"] = 0
            newData["replyCount"] = 0
            
            _ = try await commentsRef.addDocument(data: newData)
        }
    }
    
    func addReply(chineseTitle: String, reviewId: String, content: String) async throws {
        guard let user = Auth.auth().currentUser else {
            throw NSError(
                domain: "Auth",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "User not logged in"]
            )
        }
        
        let cleanTitle = chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanReviewId = reviewId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedContent.isEmpty else {
            throw NSError(
                domain: "Reply",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Reply content cannot be empty"]
            )
        }
        
        let replyData: [String: Any] = [
            "chineseTitle": cleanTitle,
            "reviewId": cleanReviewId,
            "userId": user.uid,
            "userName": user.displayName ?? user.email?.components(separatedBy: "@").first ?? "Anonymous",
            "userPhoto": user.photoURL?.absoluteString ?? "",
            "content": trimmedContent,
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp(),
            "upvoteCount": 0,
            "downvoteCount": 0
        ]
        
        _ = try await repliesCollection(chineseTitle: cleanTitle, reviewId: cleanReviewId)
            .addDocument(data: replyData)
        
        try? await commentsCollection(chineseTitle: cleanTitle)
            .document(cleanReviewId)
            .updateData([
                "replyCount": FieldValue.increment(Int64(1)),
                "updatedAt": FieldValue.serverTimestamp()
            ])
    }
    
    func voteReview(chineseTitle: String, reviewId: String, vote: ReviewVoteKind) async {
        guard let user = Auth.auth().currentUser else { return }
        
        let cleanTitle = chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanReviewId = reviewId.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let reviewRef = commentsCollection(chineseTitle: cleanTitle).document(cleanReviewId)
        let voteRef = reviewVoteDocument(
            chineseTitle: cleanTitle,
            reviewId: cleanReviewId,
            userId: user.uid
        )
        
        do {
            _ = try await db.runTransaction { transaction, errorPointer in
                let reviewSnapshot: DocumentSnapshot
                do {
                    reviewSnapshot = try transaction.getDocument(reviewRef)
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
                
                let currentUp = Self.intValue(reviewSnapshot.data()?["upvoteCount"])
                let currentDown = Self.intValue(reviewSnapshot.data()?["downvoteCount"])
                
                let existingVoteSnapshot: DocumentSnapshot?
                do {
                    existingVoteSnapshot = try transaction.getDocument(voteRef)
                } catch {
                    existingVoteSnapshot = nil
                }
                
                let existingVote = ReviewVoteKind(
                    rawValue: Self.intValue(existingVoteSnapshot?.data()?["value"])
                ) ?? .none
                
                let finalVote: ReviewVoteKind = existingVote == vote ? .none : vote
                
                var newUp = currentUp
                var newDown = currentDown
                
                switch existingVote {
                case .up: newUp = max(0, newUp - 1)
                case .down: newDown = max(0, newDown - 1)
                case .none: break
                }
                
                switch finalVote {
                case .up: newUp += 1
                case .down: newDown += 1
                case .none: break
                }
                
                transaction.updateData([
                    "upvoteCount": newUp,
                    "downvoteCount": newDown,
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: reviewRef)
                
                if finalVote == .none {
                    transaction.deleteDocument(voteRef)
                } else {
                    transaction.setData([
                        "userId": user.uid,
                        "value": finalVote.rawValue,
                        "updatedAt": FieldValue.serverTimestamp()
                    ], forDocument: voteRef, merge: true)
                }
                
                return nil
            }
        } catch {
            print("Review vote failed: \(error.localizedDescription)")
        }
    }
    
    func voteReply(chineseTitle: String, reviewId: String, replyId: String, vote: ReviewVoteKind) async {
        guard let user = Auth.auth().currentUser else { return }
        
        let cleanTitle = chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanReviewId = reviewId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanReplyId = replyId.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let replyRef = repliesCollection(chineseTitle: cleanTitle, reviewId: cleanReviewId).document(cleanReplyId)
        let voteRef = replyVoteDocument(
            chineseTitle: cleanTitle,
            reviewId: cleanReviewId,
            replyId: cleanReplyId,
            userId: user.uid
        )
        
        do {
            _ = try await db.runTransaction { transaction, errorPointer in
                let replySnapshot: DocumentSnapshot
                do {
                    replySnapshot = try transaction.getDocument(replyRef)
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
                
                let currentUp = Self.intValue(replySnapshot.data()?["upvoteCount"])
                let currentDown = Self.intValue(replySnapshot.data()?["downvoteCount"])
                
                let existingVoteSnapshot: DocumentSnapshot?
                do {
                    existingVoteSnapshot = try transaction.getDocument(voteRef)
                } catch {
                    existingVoteSnapshot = nil
                }
                
                let existingVote = ReviewVoteKind(
                    rawValue: Self.intValue(existingVoteSnapshot?.data()?["value"])
                ) ?? .none
                
                let finalVote: ReviewVoteKind = existingVote == vote ? .none : vote
                
                var newUp = currentUp
                var newDown = currentDown
                
                switch existingVote {
                case .up: newUp = max(0, newUp - 1)
                case .down: newDown = max(0, newDown - 1)
                case .none: break
                }
                
                switch finalVote {
                case .up: newUp += 1
                case .down: newDown += 1
                case .none: break
                }
                
                transaction.updateData([
                    "upvoteCount": newUp,
                    "downvoteCount": newDown,
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: replyRef)
                
                if finalVote == .none {
                    transaction.deleteDocument(voteRef)
                } else {
                    transaction.setData([
                        "userId": user.uid,
                        "value": finalVote.rawValue,
                        "updatedAt": FieldValue.serverTimestamp()
                    ], forDocument: voteRef, merge: true)
                }
                
                return nil
            }
        } catch {
            print("Reply vote failed: \(error.localizedDescription)")
        }
    }

    /// Report user-generated content to the central `reports` collection.
    /// - Parameters:
    ///   - type: `ugc_review`, `ugc_comment` or `ugc_reply`
    ///   - targetId: document id of the reported content (commentId or replyId). For reviews targetId should be the review's id (often the author's userId for reviews collection).
    ///   - targetUserId: the userId of the content author
    ///   - chineseTitle: movie title
    ///   - reason: optional user supplied reason
    ///   - parentId: for replies, the parent comment id
    func reportContent(type: String, targetId: String, targetUserId: String, chineseTitle: String, reason: String? = nil, parentId: String? = nil) async throws {
        guard let user = Auth.auth().currentUser else {
            throw NSError(domain: "Auth", code: 401, userInfo: [NSLocalizedDescriptionKey: "User not logged in"])
        }

        // sanitize title: replace / ? # [ ] * with '_'
        let sanitizedTitle = chineseTitle.replacingOccurrences(of: "[\\/\\?\\#\\[\\]\\*]", with: "_", options: .regularExpression)

        var contentPath = ""
        switch type {
        case "ugc_review":
            // reviews collection uses targetUserId as document id
            contentPath = "reviews_v2/\(sanitizedTitle)/reviews/\(targetUserId)"
        case "ugc_comment":
            contentPath = "reviews_v2/\(sanitizedTitle)/comments/\(targetId)"
        case "ugc_reply":
            if let parent = parentId {
                contentPath = "reviews_v2/\(sanitizedTitle)/comments/\(parent)/replies/\(targetId)"
            } else {
                contentPath = "reviews_v2/\(sanitizedTitle)/comments/\(targetId)"
            }
        default:
            contentPath = "reviews_v2/\(sanitizedTitle)/comments/\(targetId)"
        }

        let data: [String: Any] = [
            "reporterId": user.uid,
            "targetId": targetId,
            "targetUserId": targetUserId,
            "type": type,
            "reason": reason ?? "",
            "status": "pending",
            "createdAt": FieldValue.serverTimestamp(),
            "path": contentPath,
            "movieTitle": chineseTitle
        ]

        _ = try await db.collection("reports").addDocument(data: data)
    }
    
    func calculateWordCount(in text: String) -> Int {
        let pattern = "\\p{Han}|[a-zA-Z0-9']+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, range: range)
    }
    
    // MARK: - Private
    
    private func syncReplyListeners(chineseTitle: String, reviewIDs: Set<String>) {
        let existingIDs = Set(replyListeners.keys)
        let staleIDs = existingIDs.subtracting(reviewIDs)
        let newIDs = reviewIDs.subtracting(existingIDs)
        
        for staleID in staleIDs {
            replyListeners[staleID]?.remove()
            replyListeners[staleID] = nil
        }
        
        for reviewId in newIDs {
            replyListeners[reviewId] = repliesCollection(chineseTitle: chineseTitle, reviewId: reviewId)
                .order(by: "createdAt", descending: false)
                .addSnapshotListener { [weak self] snapshot, error in
                    guard let self else { return }
                    if let error {
                        print("Reply listener error: \(error.localizedDescription)")
                        return
                    }
                    
                    let documents = snapshot?.documents ?? []
                    
                    Task {
                        let uid = Auth.auth().currentUser?.uid
                        var loadedReplies: [ReviewReply] = []
                        
                        for document in documents {
                            var reply = self.reply(from: document, chineseTitle: chineseTitle, reviewId: reviewId)
                            
                            if let uid {
                                reply.userVote = await self.fetchVoteKind(
                                    at: self.replyVoteDocument(
                                        chineseTitle: chineseTitle,
                                        reviewId: reviewId,
                                        replyId: reply.id,
                                        userId: uid
                                    )
                                )
                            }
                            
                            loadedReplies.append(reply)
                        }
                        
                        await MainActor.run {
                            guard let index = self.rawComments.firstIndex(where: { $0.id == reviewId }) else { return }
                            self.rawComments[index].replies = loadedReplies
                            self.publishReviews()
                        }
                    }
                }
        }
    }
    
    private func fetchReplies(chineseTitle: String, reviewId: String) async -> [ReviewReply] {
        do {
            let snapshot = try await repliesCollection(chineseTitle: chineseTitle, reviewId: reviewId)
                .order(by: "createdAt", descending: false)
                .getDocuments()
            
            let uid = Auth.auth().currentUser?.uid
            var replies: [ReviewReply] = []
            
            for document in snapshot.documents {
                var reply = self.reply(from: document, chineseTitle: chineseTitle, reviewId: reviewId)
                
                if let uid {
                    reply.userVote = await fetchVoteKind(
                        at: replyVoteDocument(
                            chineseTitle: chineseTitle,
                            reviewId: reviewId,
                            replyId: reply.id,
                            userId: uid
                        )
                    )
                }
                
                replies.append(reply)
            }
            
            return replies
        } catch {
            print("Fetch replies failed: \(error.localizedDescription)")
            return []
        }
    }
    
    private func fetchVoteKind(at document: DocumentReference) async -> ReviewVoteKind {
        do {
            let snapshot = try await document.getDocument()
            return ReviewVoteKind(rawValue: Self.intValue(snapshot.data()?["value"])) ?? .none
        } catch {
            return .none
        }
    }
    
    private func commentsCollection(chineseTitle: String) -> CollectionReference {
        db.collection("reviews_v2")
            .document(chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines))
            .collection("comments")
    }
    
    private func repliesCollection(chineseTitle: String, reviewId: String) -> CollectionReference {
        commentsCollection(chineseTitle: chineseTitle)
            .document(reviewId.trimmingCharacters(in: .whitespacesAndNewlines))
            .collection("replies")
    }
    
    private func reviewVoteDocument(chineseTitle: String, reviewId: String, userId: String) -> DocumentReference {
        commentsCollection(chineseTitle: chineseTitle)
            .document(reviewId.trimmingCharacters(in: .whitespacesAndNewlines))
            .collection("votes")
            .document(userId)
    }
    
    private func replyVoteDocument(chineseTitle: String, reviewId: String, replyId: String, userId: String) -> DocumentReference {
        repliesCollection(chineseTitle: chineseTitle, reviewId: reviewId)
            .document(replyId.trimmingCharacters(in: .whitespacesAndNewlines))
            .collection("votes")
            .document(userId)
    }
    
    private func review(from document: DocumentSnapshot, chineseTitle: String) -> Review {
        let data = document.data() ?? [:]
        
        return Review(
            id: document.documentID,
            chineseTitle: Self.stringValue(data["chineseTitle"], fallback: chineseTitle),
            userId: Self.stringValue(data["userId"]),
            userName: Self.stringValue(data["userName"], fallback: "Anonymous"),
            userPhoto: Self.optionalStringValue(data["userPhoto"]),
            content: Self.stringValue(data["content"]),
            rating: Self.doubleValue(data["rating"], fallback: 5), // will be overridden by the live ratings listener
            createdAt: Self.dateValue(data["createdAt"]),
            updatedAt: Self.optionalDateValue(data["updatedAt"]),
            upvoteCount: Self.intValue(data["upvoteCount"]),
            downvoteCount: Self.intValue(data["downvoteCount"]),
            userVote: .none,
            replies: []
        )
    }
    
    private func reply(from document: DocumentSnapshot, chineseTitle: String, reviewId: String) -> ReviewReply {
        let data = document.data() ?? [:]
        
        return ReviewReply(
            id: document.documentID,
            chineseTitle: Self.stringValue(data["chineseTitle"], fallback: chineseTitle),
            reviewId: Self.stringValue(data["reviewId"], fallback: reviewId),
            userId: Self.stringValue(data["userId"]),
            userName: Self.stringValue(data["userName"], fallback: "Anonymous"),
            userPhoto: Self.optionalStringValue(data["userPhoto"]),
            content: Self.stringValue(data["content"]),
            createdAt: Self.dateValue(data["createdAt"]),
            updatedAt: Self.optionalDateValue(data["updatedAt"]),
            upvoteCount: Self.intValue(data["upvoteCount"]),
            downvoteCount: Self.intValue(data["downvoteCount"]),
            userVote: .none
        )
    }
    
    private static func stringValue(_ raw: Any?, fallback: String = "") -> String {
        if let value = raw as? String { return value }
        return fallback
    }
    
    private static func optionalStringValue(_ raw: Any?) -> String? {
        if let value = raw as? String, !value.isEmpty { return value }
        return nil
    }
    
    private static func intValue(_ raw: Any?) -> Int {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? Double { return Int(value) }
        return 0
    }
    
    private static func doubleValue(_ raw: Any?, fallback: Double = 0) -> Double {
        if let value = raw as? Double { return value }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? Int { return Double(value) }
        return fallback
    }
    
    private static func dateValue(_ raw: Any?) -> Date {
        if let timestamp = raw as? Timestamp { return timestamp.dateValue() }
        if let date = raw as? Date { return date }
        if let string = raw as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: string) { return date }
        }
        return Date()
    }
    
    private static func optionalDateValue(_ raw: Any?) -> Date? {
        if raw == nil { return nil }
        return dateValue(raw)
    }
}

// MARK: - Review UI

struct ReviewRow: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(ReviewManager.self) private var reviewManager
    @Environment(AuthManager.self) private var auth
    @Environment(BlockedUserManager.self) private var blockedManager
    
    let review: Review
    
    @State private var isReplying = false
    @State private var replyText = ""
    @State private var isSubmittingReply = false
    @State private var replyError: String?
    @State private var showReportDialog = false
    @State private var showReportCustomSheet = false
    @State private var reportReason = ""
    @State private var isReporting = false
    @State private var showBlockConfirm = false
    @State private var infoMessage: String?
    @State private var showInfoMessage = false
    
    private var roundedRating: Int {
        Int(review.displayRating.rounded())
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { index in
                    Image(systemName: index <= roundedRating ? "star.fill" : "star")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
                
                Text(String(format: "%.1f/5", review.displayRating))
                    .font(.caption)
                    .bold()
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            
            if blockedManager.isBlocked(review.userId) {
                Text("[此用戶已封鎖 (Blocked)]")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(review.content)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            voteBar(
                upCount: review.upvoteCount,
                downCount: review.downvoteCount,
                currentVote: review.userVote,
                onUpvote: {
                    Task { await reviewManager.voteReview(chineseTitle: review.chineseTitle, reviewId: review.id, vote: .up) }
                },
                onDownvote: {
                    Task { await reviewManager.voteReview(chineseTitle: review.chineseTitle, reviewId: review.id, vote: .down) }
                },
                replyAction: {
                    if auth.isSignedIn {
                        withAnimation {
                            isReplying.toggle()
                        }
                    }
                }
            )
            
            if isReplying {
                replyComposer
            }
            
            if !review.replies.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(review.replies) { reply in
                        ReviewReplyRowView(
                            chineseTitle: review.chineseTitle,
                            reviewId: review.id,
                            reply: reply
                        )
                    }
                }
                .padding(.leading, 16)
                .padding(.top, 2)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .confirmationDialog(lang.t("檢舉此評論", "举报此评论", "Report this review"), isPresented: $showReportDialog, titleVisibility: .visible) {
            Button(lang.t("垃圾訊息", "垃圾信息", "Spam")) { Task { await report(reason: "Spam") } }
            Button(lang.t("騷擾/辱罵", "骚扰/辱骂", "Harassment/Abuse")) { Task { await report(reason: "Harassment/Abuse") } }
            Button(lang.t("不適當內容", "不适当内容", "Inappropriate Content")) { Task { await report(reason: "Inappropriate") } }
            Button(lang.t("其他", "其他", "Other")) { showReportCustomSheet = true }
            Button(lang.t("取消", "取消", "Cancel"), role: .cancel) { }
        }
        .alert(Text(lang.t("確定要封鎖此用戶嗎？", "确定要封锁此用户吗？", "Block this user?")), isPresented: $showBlockConfirm) {
            Button(lang.t("封鎖", "封锁", "Block"), role: .destructive) { toggleBlock() }
            Button(lang.t("取消", "取消", "Cancel"), role: .cancel) { }
        } message: {
            Text(lang.t("被封鎖的用戶將不會顯示於您的評論列表中。", "被封锁的用户将不会显示于您的评论列表中。", "Blocked users will no longer appear in your reviews list."))
        }
        .alert(isPresented: $showInfoMessage) {
            Alert(title: Text(infoMessage ?? ""))
        }
        .sheet(isPresented: $showReportCustomSheet) {
            NavigationStack {
                Form {
                    Section {
                        TextField(lang.t("檢舉原因 (選填)", "举报原因 (选填)", "Reason (optional)"), text: $reportReason)
                    }
                }
                .navigationTitle(lang.t("檢舉評論", "举报评论", "Report Review"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(lang.t("取消", "取消", "Cancel")) { showReportCustomSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isReporting { ProgressView() } else {
                            Button(lang.t("送出檢舉", "发送举报", "Send Report")) {
                                Task { await report(reason: reportReason) }
                            }
                        }
                    }
                }
            }
        }
    }
    
    private var header: some View {
        HStack(spacing: 10) {
            AsyncImage(url: URL(string: review.userPhoto ?? "")) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .foregroundColor(.gray.opacity(0.5))
            }
            .frame(width: 34, height: 34)
            .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 2) {
                Text(review.displayUserName)
                    .font(.subheadline)
                    .bold()
                
                Text(review.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            Menu {
                Button {
                    // Open report dialog
                    showReportDialog = true
                } label: {
                    Label(lang.t("檢舉評論", "举报评论", "Report Review"), systemImage: "flag")
                }

                Button {
                    showBlockConfirm = true
                } label: {
                    if blockedManager.isBlocked(review.userId) {
                        Label(lang.t("取消封鎖用戶", "取消封锁用户", "Unblock User"), systemImage: "person.crop.circle.badge.checkmark")
                    } else {
                        Label(lang.t("封鎖用戶", "封锁用户", "Block User"), systemImage: "person.crop.circle.badge.xmark")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private var replyComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                lang.t("回覆這則評論...", "回复这则评论...", "Reply to this review..."),
                text: $replyText,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...5)
            
            if let replyError {
                Text(replyError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            HStack {
                Spacer()
                
                if isSubmittingReply {
                    ProgressView()
                } else {
                    Button(lang.t("送出回覆", "发送回复", "Send Reply")) {
                        Task { await submitReply() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
    
    @ViewBuilder
    private func voteBar(
        upCount: Int,
        downCount: Int,
        currentVote: ReviewVoteKind,
        onUpvote: @escaping () -> Void,
        onDownvote: @escaping () -> Void,
        replyAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Button(action: onUpvote) {
                Label("\(upCount)", systemImage: currentVote == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .labelStyle(.titleAndIcon)
                    .foregroundColor(currentVote == .up ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!auth.isSignedIn)
            
            Button(action: onDownvote) {
                Label("\(downCount)", systemImage: currentVote == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .labelStyle(.titleAndIcon)
                    .foregroundColor(currentVote == .down ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!auth.isSignedIn)
            
            Spacer()
            
            Button(auth.isSignedIn ? lang.t("回覆", "回复", "Reply") : lang.t("登入後可回覆", "登录后可回复", "Sign in to reply")) {
                replyAction()
            }
            .buttonStyle(.plain)
            .foregroundColor(.blue)
        }
        .font(.caption)
    }
    
    private func submitReply() async {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            replyError = lang.t("回覆內容不能為空。", "回复内容不能为空。", "Reply content cannot be empty.")
            return
        }
        
        isSubmittingReply = true
        replyError = nil
        defer { isSubmittingReply = false }
        
        do {
            try await reviewManager.addReply(
                chineseTitle: review.chineseTitle,
                reviewId: review.id,
                content: trimmed
            )
            replyText = ""
            withAnimation {
                isReplying = false
            }
        } catch {
            replyError = error.localizedDescription
        }
    }

    private func report(reason: String?) async {
        guard auth.isSignedIn else {
            infoMessage = lang.t("請先登入後再檢舉。", "请先登录后再举报。", "Please sign in before reporting.")
            showInfoMessage = true
            return
        }

        isReporting = true
        defer { isReporting = false }

        do {
            try await reviewManager.reportContent(
                type: "ugc_review",
                targetId: review.id,
                targetUserId: review.userId,
                chineseTitle: review.chineseTitle,
                reason: reason
            )
            infoMessage = lang.t("檢舉已送出。感謝您的回報。", "举报已发送。感谢您的反馈。", "Report sent. Thank you for your feedback.")
            showInfoMessage = true
            showReportDialog = false
            showReportCustomSheet = false
            reportReason = ""
        } catch {
            infoMessage = error.localizedDescription
            showInfoMessage = true
        }
    }

    private func toggleBlock() {
        guard auth.isSignedIn else {
            infoMessage = lang.t("請先登入後再封鎖用戶。", "请先登录后再封锁用户。", "Please sign in before blocking users.")
            showInfoMessage = true
            return
        }

        if blockedManager.isBlocked(review.userId) {
            blockedManager.unblock(review.userId)
            infoMessage = lang.t("已取消封鎖。", "已取消封锁。", "User unblocked.")
        } else {
            blockedManager.block(review.userId)
            infoMessage = lang.t("已封鎖此用戶，該用戶的評論將不再顯示。", "已封锁此用户，该用户的评论将不再显示。", "User blocked. Their reviews will be hidden.")
        }
        showInfoMessage = true
    }
}

private struct ReviewReplyRowView: View {
    @Environment(ReviewManager.self) private var reviewManager
    @Environment(AuthManager.self) private var auth
    
    let chineseTitle: String
    let reviewId: String
    let reply: ReviewReply
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AsyncImage(url: URL(string: reply.userPhoto ?? "")) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundColor(.gray.opacity(0.5))
                }
                .frame(width: 26, height: 26)
                .clipShape(Circle())
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(reply.displayUserName)
                        .font(.caption)
                        .bold()
                    Text(reply.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            Text(reply.content)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            
            HStack(spacing: 14) {
                Button {
                    Task {
                        await reviewManager.voteReply(
                            chineseTitle: chineseTitle,
                            reviewId: reviewId,
                            replyId: reply.id,
                            vote: .up
                        )
                    }
                } label: {
                    Label(
                        "\(reply.upvoteCount)",
                        systemImage: reply.userVote == .up ? "hand.thumbsup.fill" : "hand.thumbsup"
                    )
                    .foregroundColor(reply.userVote == .up ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!auth.isSignedIn)
                
                Button {
                    Task {
                        await reviewManager.voteReply(
                            chineseTitle: chineseTitle,
                            reviewId: reviewId,
                            replyId: reply.id,
                            vote: .down
                        )
                    }
                } label: {
                    Label(
                        "\(reply.downvoteCount)",
                        systemImage: reply.userVote == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown"
                    )
                    .foregroundColor(reply.userVote == .down ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!auth.isSignedIn)
                
                Spacer()
            }
            .font(.caption)
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(10)
    }
}
