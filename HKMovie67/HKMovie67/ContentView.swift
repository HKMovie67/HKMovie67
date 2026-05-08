//
//  ContentView.swift
//  HKMovie67
//
//  Created by Y. Sunny Lai on 3/1/26.
//

import SwiftUI
import Observation
import CoreLocation
import FirebaseAuth
import FirebaseFirestore
import PhotosUI
import SafariServices

// MARK: - Location Manager
@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {
    var location: CLLocation?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private let manager = CLLocationManager()
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        self.authorizationStatus = manager.authorizationStatus
        
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }
    
    func requestLocation() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.first
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager error: \(error.localizedDescription)")
    }
}

// MARK: - Premium Subscription Manager
@Observable
final class PremiumManager {
    var selectedFreeOptionId: String? {
        didSet { UserDefaults.standard.set(selectedFreeOptionId, forKey: "selectedFreeOptionId") }
    }
    var trialStartTimestamp: Double {
        didSet { UserDefaults.standard.set(trialStartTimestamp, forKey: "premiumTrialStartTimestamp") }
    }
    var isSubscribed: Bool {
        didSet { UserDefaults.standard.set(isSubscribed, forKey: "isPremiumSubscribed") }
    }
    
    init() {
        self.selectedFreeOptionId = UserDefaults.standard.string(forKey: "selectedFreeOptionId")
        self.trialStartTimestamp = UserDefaults.standard.double(forKey: "premiumTrialStartTimestamp")
        self.isSubscribed = UserDefaults.standard.bool(forKey: "isPremiumSubscribed")
    }
    
    var isTrialActive: Bool {
        guard trialStartTimestamp > 0 else { return false }
        let diff = Date().timeIntervalSince1970 - trialStartTimestamp
        return diff < (7 * 86400)
    }
    
    var trialExpired: Bool {
        guard trialStartTimestamp > 0 else { return false }
        let diff = Date().timeIntervalSince1970 - trialStartTimestamp
        return diff >= (7 * 86400)
    }
    
    func selectFreeOption(_ id: String) {
        guard selectedFreeOptionId == nil else { return }
        selectedFreeOptionId = id
    }
    
    func startTrial() {
        guard trialStartTimestamp == 0 else { return }
        trialStartTimestamp = Date().timeIntervalSince1970
    }
    
    func subscribe() {
        isSubscribed = true
    }
    
    func isUnlocked(_ id: String) -> Bool {
        if id == "achievements" { return true }
        if isSubscribed { return true }
        if isTrialActive { return true }
        return selectedFreeOptionId == id
    }
}

// MARK: - Local User Data Manager

struct WatchedItem: Identifiable, Hashable {
    var id: String { movieTitle }
    let movieTitle: String
    let posterUrl: String
    let tmdbId: String
    let watchedAt: Date
}

struct ImportedMovieSelection: Identifiable {
    let id = UUID()
    var extractedText: String = ""
    var selectedMovie: TMDBMovie?
    var isSearching = true
}

@Observable
final class WatchedManager {
    var watchedMovieTitles: Set<String> {
        didSet { UserDefaults.standard.set(Array(watchedMovieTitles), forKey: "watchedMovieTitles") }
    }
    var skippedMovieTitles: Set<String> {
        didSet { UserDefaults.standard.set(Array(skippedMovieTitles), forKey: "skippedMovieTitles") }
    }
    
    // To properly display manual additions synced from web
    var watchedItems: [WatchedItem] = []
    
    private let db = Firestore.firestore(database: "ai-studio-c2f1ae4d-bb2b-48e7-876b-c75e5b54a82f")
    private var watchedListener: ListenerRegistration?
    private var skippedListener: ListenerRegistration?
    
    init() {
        // Fallback to legacy UserDefaults arrays to migrate existing users over gracefully
        let legacyWatched = UserDefaults.standard.stringArray(forKey: "watchedMovieIDs") ?? []
        let legacySkipped = UserDefaults.standard.stringArray(forKey: "skippedMovieIDs") ?? []
        
        self.watchedMovieTitles = Set(UserDefaults.standard.stringArray(forKey: "watchedMovieTitles") ?? legacyWatched)
        self.skippedMovieTitles = Set(UserDefaults.standard.stringArray(forKey: "skippedMovieTitles") ?? legacySkipped)
    }
    
    func startListening() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        stopListening()
        
        // 1. Listen to the new web-synced `watched_v2` collection
        watchedListener = db.collection("users")
            .document(uid)
            .collection("watched_v2")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self = self, let documents = snapshot?.documents else { return }
                
                var newWatched = Set<String>()
                var newItems = [WatchedItem]()
                
                for doc in documents {
                    let title = doc.documentID // Chinese title is used as the document ID
                    newWatched.insert(title)
                    
                    let data = doc.data()
                    let posterUrl = data["posterUrl"] as? String ?? ""
                    let tmdbId = data["tmdbId"] as? String ?? ""
                    let watchedAt = (data["watchedAt"] as? Timestamp)?.dateValue() ?? Date()
                    
                    newItems.append(WatchedItem(movieTitle: title, posterUrl: posterUrl, tmdbId: tmdbId, watchedAt: watchedAt))
                }
                
                // Most recently watched at the top
                newItems.sort { $0.watchedAt > $1.watchedAt }
                
                Task { @MainActor in
                    // Merge dynamically so legacy overrides don't break our sync state
                    self.watchedMovieTitles.formUnion(newWatched)
                    self.watchedItems = newItems
                }
            }
        
        // 2. Listen to legacy `movieStates` for skipped movies
        skippedListener = db.collection("users")
            .document(uid)
            .collection("movieStates")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self = self, let documents = snapshot?.documents else { return }
                
                var newSkipped = Set<String>()
                for doc in documents {
                    if let isSkipped = doc.data()["is_not_interested"] as? Bool, isSkipped {
                        newSkipped.insert(doc.documentID)
                    }
                }
                
                Task { @MainActor in
                    self.skippedMovieTitles.formUnion(newSkipped)
                }
            }
    }
    
    func stopListening() {
        watchedListener?.remove()
        watchedListener = nil
        
        skippedListener?.remove()
        skippedListener = nil
    }
    
    func toggleWatched(for movie: Movie) {
        let cleanTitle = movie.chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if isWatched(cleanTitle) {
            watchedMovieTitles.remove(cleanTitle)
            watchedItems.removeAll { $0.movieTitle == cleanTitle } // Optimistic UI
            removeWatchedFromFirebase(cleanTitle)
        } else {
            watchedMovieTitles.insert(cleanTitle)
            skippedMovieTitles.remove(cleanTitle)
            addWatchedToFirebase(movie)
            removeSkippedFromFirebase(cleanTitle)
        }
    }
    
    func toggleSkipped(for movie: Movie) {
        let cleanTitle = movie.chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSkipped(cleanTitle) {
            skippedMovieTitles.remove(cleanTitle)
            removeSkippedFromFirebase(cleanTitle)
        } else {
            skippedMovieTitles.insert(cleanTitle)
            watchedMovieTitles.remove(cleanTitle)
            watchedItems.removeAll { $0.movieTitle == cleanTitle } // Optimistic UI
            addSkippedToFirebase(cleanTitle)
            removeWatchedFromFirebase(cleanTitle)
        }
    }
    
    // Hardened check: looks at both local set and the strictly synced array
    func isWatched(_ chineseTitle: String) -> Bool {
        let clean = chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return watchedItems.contains(where: { $0.movieTitle == clean }) || watchedMovieTitles.contains(clean)
    }
    
    func isSkipped(_ chineseTitle: String) -> Bool {
        skippedMovieTitles.contains(chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    // Manual TMDb Add
    func addManualWatched(tmdbMovie: TMDBMovie) {
        let cleanTitle = (tmdbMovie.title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        
        let posterUrl = tmdbMovie.poster_path != nil ? "https://image.tmdb.org/t/p/w500\(tmdbMovie.poster_path!)" : ""
        
        // Optimistic UI updates
        watchedMovieTitles.insert(cleanTitle)
        skippedMovieTitles.remove(cleanTitle)
        if !watchedItems.contains(where: { $0.movieTitle == cleanTitle }) {
            watchedItems.insert(WatchedItem(movieTitle: cleanTitle, posterUrl: posterUrl, tmdbId: "\(tmdbMovie.id)", watchedAt: Date()), at: 0)
        }
        
        guard let uid = Auth.auth().currentUser?.uid else { return }
        
        let data: [String: Any] = [
            "userId": uid,
            "movieTitle": cleanTitle,
            "posterUrl": posterUrl,
            "tmdbId": "\(tmdbMovie.id)",
            "watchedAt": FieldValue.serverTimestamp()
        ]
        
        db.collection("users")
            .document(uid)
            .collection("watched_v2")
            .document(cleanTitle)
            .setData(data, merge: true)
            
        removeSkippedFromFirebase(cleanTitle)
    }
    
    func deleteWatchedItem(_ title: String) {
        watchedMovieTitles.remove(title)
        watchedItems.removeAll { $0.movieTitle == title } // Optimistic UI update
        removeWatchedFromFirebase(title)
    }
    
    // MARK: - Firebase Mutators
    
    private func addWatchedToFirebase(_ movie: Movie) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let cleanTitle = movie.chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let data: [String: Any] = [
            "userId": uid,
            "movieTitle": cleanTitle,
            "posterUrl": movie.posterURL ?? "",
            "tmdbId": movie.tmdbid ?? movie.id, // Favor TMDB ID if present, otherwise fallback
            "watchedAt": FieldValue.serverTimestamp()
        ]
        
        db.collection("users")
            .document(uid)
            .collection("watched_v2")
            .document(cleanTitle)
            .setData(data, merge: true)
    }
    
    private func removeWatchedFromFirebase(_ chineseTitle: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        db.collection("users")
            .document(uid)
            .collection("watched_v2")
            .document(chineseTitle)
            .delete()
    }
    
    private func addSkippedToFirebase(_ chineseTitle: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        db.collection("users")
            .document(uid)
            .collection("movieStates")
            .document(chineseTitle)
            .setData([
                "is_not_interested": true,
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
    }
    
    private func removeSkippedFromFirebase(_ chineseTitle: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        db.collection("users")
            .document(uid)
            .collection("movieStates")
            .document(chineseTitle)
            .setData([
                "is_not_interested": false,
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
    }
}

// MARK: - App Data Models
struct Movie: Identifiable, Codable, Equatable {
    var id: String
    var tmdbid: String?
    var imdbid: String?
    var englishTitle: String
    var chineseTitle: String
    var introText: String?
    var distributor: String?
    var movieLengthMinute: Int?
    var ageLimit: String?
    var castText: String?
    var releaseDate: Date
    var posterURL: String?
    var trailerURL: String?
    var movieType: String?
    var forceScreening: Bool?
    var isUrgent: Bool?
    var isOffCinema: Bool?
    var wmoovURL: String?
    var hkmovieURL: String?
    var enjoymovieURL: String?
    
    var isScreeningNow: Bool {
        if let forceScreening = forceScreening { return forceScreening }
        let today = Calendar.current.startOfDay(for: Date())
        let release = Calendar.current.startOfDay(for: releaseDate)
        return release <= today
    }
    
    var daysUntilScreening: Int {
        max(
            Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: Date()),
                to: Calendar.current.startOfDay(for: releaseDate)
            ).day ?? 0,
            0
        )
    }
    
    var daysSinceScreening: Int {
        max(
            Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: releaseDate),
                to: Calendar.current.startOfDay(for: Date())
            ).day ?? 0,
            0
        )
    }
    
    var urgencyColor: Color {
        daysSinceScreening <= 3 ? .green : (daysSinceScreening <= 6 ? .orange : .red)
    }
    
    var normalizedMovieType: String {
        (movieType ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }
    
    var movieTypeSortPriority: Int {
        switch normalizedMovieType {
        case "CANTO": return 0
        case "CHI": return 1
        case "OTHER": return 2
        default: return 3
        }
    }
    
    var englishIndexLetter: String {
        // 1. Try English Title first
        let engTrimmed = englishTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = engTrimmed.first {
            let upper = String(first).uppercased()
            if upper.range(of: "^[A-Z]$", options: .regularExpression) != nil {
                return upper
            }
        }
        
        // 2. Fallback: Transliterate the first Chinese character into Pinyin (Latin alphabet)
        let chiTrimmed = chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstChi = chiTrimmed.first {
            let chiStr = String(firstChi)
            if let latin = chiStr.applyingTransform(.toLatin, reverse: false),
               let stripped = latin.applyingTransform(.stripDiacritics, reverse: false),
               let firstLatin = stripped.first {
                let upper = String(firstLatin).uppercased()
                if upper.range(of: "^[A-Z]$", options: .regularExpression) != nil {
                    return upper
                }
            }
        }
        
        return "#"
    }
    
    init(
        id: String = UUID().uuidString,
        tmdbid: String? = nil,
        imdbid: String? = nil,
        englishTitle: String,
        chineseTitle: String,
        introText: String? = nil,
        distributor: String? = nil,
        movieLengthMinute: Int? = nil,
        ageLimit: String? = nil,
        castText: String? = nil,
        releaseDate: Date,
        posterURL: String? = nil,
        trailerURL: String? = nil,
        movieType: String? = "CANTO",
        wmoovURL: String? = nil,
        hkmovieURL: String? = nil,
        enjoymovieURL: String? = nil,
        forceScreening: Bool? = nil,
        isUrgent: Bool? = nil,
        isOffCinema: Bool? = nil
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tmdbid = tmdbid
        self.imdbid = imdbid
        self.englishTitle = englishTitle
        self.chineseTitle = chineseTitle
        self.introText = introText
        self.distributor = distributor
        self.movieLengthMinute = movieLengthMinute
        self.ageLimit = ageLimit
        self.castText = castText
        self.releaseDate = releaseDate
        self.posterURL = posterURL
        self.trailerURL = trailerURL
        self.movieType = movieType
        self.wmoovURL = wmoovURL
        self.hkmovieURL = hkmovieURL
        self.enjoymovieURL = enjoymovieURL
        self.forceScreening = forceScreening
        self.isUrgent = isUrgent
        self.isOffCinema = isOffCinema
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case tmdbid
        case imdbid
        case englishTitle
        case chineseTitle
        case introText = "Introtext"
        case distributor = "Distributor"
        case movieLengthMinute = "MovieLengthMinute"
        case ageLimit = "AgeLimit"
        case castText = "Cast"
        case releaseDate
        case posterURL
        case trailerURL
        case movieType
        case movieTypeSheet = "movieTypeCANTOorCHIorOTHER"
        case wmoovURL
        case hkmovieURL
        case enjoymovieURL
        case forceScreening
        case isUrgent
        case isOffCinema
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.id = (try? container.decode(String.self, forKey: .id))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? UUID().uuidString
        
        if let intTmdb = try? container.decodeIfPresent(Int.self, forKey: .tmdbid) {
            self.tmdbid = String(intTmdb)
        } else {
            self.tmdbid = try? container.decodeIfPresent(String.self, forKey: .tmdbid)
        }
        
        if let intImdb = try? container.decodeIfPresent(Int.self, forKey: .imdbid) {
            self.imdbid = String(intImdb)
        } else {
            self.imdbid = try? container.decodeIfPresent(String.self, forKey: .imdbid)
        }
        
        self.englishTitle = (try? container.decode(String.self, forKey: .englishTitle)) ?? "Unknown"
        self.chineseTitle = (try? container.decode(String.self, forKey: .chineseTitle)) ?? "未知"
        self.introText = try? container.decodeIfPresent(String.self, forKey: .introText)
        self.distributor = try? container.decodeIfPresent(String.self, forKey: .distributor)
        self.ageLimit = try? container.decodeIfPresent(String.self, forKey: .ageLimit)
        self.castText = try? container.decodeIfPresent(String.self, forKey: .castText)
        
        if let value = try? container.decodeIfPresent(Int.self, forKey: .movieLengthMinute) {
            self.movieLengthMinute = value
        } else if let value = try? container.decodeIfPresent(String.self, forKey: .movieLengthMinute) {
            self.movieLengthMinute = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let value = try? container.decodeIfPresent(Double.self, forKey: .movieLengthMinute) {
            self.movieLengthMinute = Int(value)
        } else {
            self.movieLengthMinute = nil
        }
        
        if let ds = try? container.decode(String.self, forKey: .releaseDate) {
            let formats = ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"]
            let formatter = DateFormatter()
            var parsedDate: Date?
            for format in formats {
                formatter.dateFormat = format
                if let d = formatter.date(from: ds) {
                    parsedDate = d
                    break
                }
            }
            self.releaseDate = parsedDate ?? Date()
        } else {
            self.releaseDate = Date()
        }
        
        self.movieType =
            (try? container.decodeIfPresent(String.self, forKey: .movieType)) ??
            (try? container.decodeIfPresent(String.self, forKey: .movieTypeSheet))
        
        self.posterURL = try? container.decodeIfPresent(String.self, forKey: .posterURL)
        self.trailerURL = try? container.decodeIfPresent(String.self, forKey: .trailerURL)
        self.wmoovURL = try? container.decodeIfPresent(String.self, forKey: .wmoovURL)
        self.hkmovieURL = try? container.decodeIfPresent(String.self, forKey: .hkmovieURL)
        self.enjoymovieURL = try? container.decodeIfPresent(String.self, forKey: .enjoymovieURL)
        self.forceScreening = try? container.decodeIfPresent(Bool.self, forKey: .forceScreening)
        self.isUrgent = try? container.decodeIfPresent(Bool.self, forKey: .isUrgent)
        self.isOffCinema = try? container.decodeIfPresent(Bool.self, forKey: .isOffCinema)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(tmdbid, forKey: .tmdbid)
        try container.encodeIfPresent(imdbid, forKey: .imdbid)
        try container.encode(englishTitle, forKey: .englishTitle)
        try container.encode(chineseTitle, forKey: .chineseTitle)
        try container.encodeIfPresent(introText, forKey: .introText)
        try container.encodeIfPresent(distributor, forKey: .distributor)
        try container.encodeIfPresent(movieLengthMinute, forKey: .movieLengthMinute)
        try container.encodeIfPresent(ageLimit, forKey: .ageLimit)
        try container.encodeIfPresent(castText, forKey: .castText)
        try container.encode(releaseDate, forKey: .releaseDate)
        try container.encodeIfPresent(posterURL, forKey: .posterURL)
        try container.encodeIfPresent(trailerURL, forKey: .trailerURL)
        try container.encodeIfPresent(movieType, forKey: .movieType)
        try container.encodeIfPresent(movieType, forKey: .movieTypeSheet)
        try container.encodeIfPresent(wmoovURL, forKey: .wmoovURL)
        try container.encodeIfPresent(hkmovieURL, forKey: .hkmovieURL)
        try container.encodeIfPresent(enjoymovieURL, forKey: .enjoymovieURL)
        try container.encodeIfPresent(forceScreening, forKey: .forceScreening)
        try container.encodeIfPresent(isUrgent, forKey: .isUrgent)
        try container.encodeIfPresent(isOffCinema, forKey: .isOffCinema)
    }
}

struct MovieSearchResult: Identifiable {
    let id: String
    let source: String
    let englishTitle: String
    let chineseTitle: String
    let releaseDate: Date
    let posterURL: String?
    let movieType: String
    
    var asMovie: Movie {
        Movie(
            id: id,
            englishTitle: englishTitle,
            chineseTitle: chineseTitle,
            releaseDate: releaseDate,
            posterURL: posterURL,
            trailerURL: nil,
            movieType: movieType,
            isUrgent: nil
        )
    }
}

struct TMDBResponse: Codable { let results: [TMDBMovie] }
struct TMDBMovie: Codable {
    let id: Int
    let title: String
    let original_title: String?
    let release_date: String?
    let poster_path: String?
    let original_language: String?
}

// MARK: - Managers
@Observable
final class MovieManager {
    var movies: [Movie] = []
    var isFetching = false
    var hasFetchedThisSession = false
    
    private let endpoint = "https://script.google.com/macros/s/AKfycbzlRNBsHHXQ0HzaMl2Xm3qv1civiaMA9yx2HjGvoNR8Yk93Er7HXdVylaEoiCCO9pBCHw/exec"
    private var cacheFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("moviesCache.json")
    }
    
    init() {
        let memoryCapacity = 250 * 1024 * 1024 // 250 MB
        let diskCapacity = 2 * 1024 * 1024 * 1024 // 2 GB
        let cache = URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, diskPath: "movie_image_cache")
        URLCache.shared = cache
        
        loadFromCache()
    }
    
    func fetchMovies(force: Bool = false) async {
        guard !isFetching, let url = URL(string: endpoint) else { return }
        
        if !force && hasFetchedThisSession && !movies.isEmpty { return }
        
        isFetching = true
        defer { isFetching = false }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoder = JSONDecoder()
            let decodedMovies = try decoder.decode([Movie].self, from: data)
            await MainActor.run {
                self.movies = decodedMovies.sorted { $0.releaseDate > $1.releaseDate }
                self.hasFetchedThisSession = true
                saveToCache(decodedMovies)
            }
            
            Task {
                await enrichMissingData()
            }
        } catch {
            print("Fetch failed: \(error)")
        }
    }
    
    func enrichMissingData() async {
        var updatedMovies = self.movies
        var hasChanges = false
        
        for (index, movie) in updatedMovies.enumerated() {
            let needsPoster = movie.posterURL == nil || movie.posterURL!.isEmpty
            let needsTrailer = movie.trailerURL == nil || movie.trailerURL!.isEmpty
            
            if needsPoster || needsTrailer {
                let enrichment = await TMDBService.shared.enrichment(for: movie)
                if enrichment.posterURL != movie.posterURL || enrichment.trailerURL != movie.trailerURL {
                    updatedMovies[index].posterURL = enrichment.posterURL ?? movie.posterURL
                    updatedMovies[index].trailerURL = enrichment.trailerURL ?? movie.trailerURL
                    hasChanges = true
                    
                    let newlyEnrichedMovie = updatedMovies[index]
                    await MainActor.run {
                        if let i = self.movies.firstIndex(where: { $0.id == newlyEnrichedMovie.id }) {
                            self.movies[i] = newlyEnrichedMovie
                        }
                    }
                }
            }
        }
        
        if hasChanges {
            await MainActor.run {
                self.saveToCache(self.movies)
            }
            
            await overwriteAllMovies(with: self.movies)
        }
    }
    
    func addMovie(_ movie: Movie, fetchAfter: Bool = true) async {
        var list = movies
        list.append(movie)
        await overwriteAllMovies(with: list)
    }
    
    func updateMovie(_ movie: Movie) async {
        var curr = movies
        if let idx = curr.firstIndex(where: { $0.id == movie.id }) {
            curr[idx] = movie
        }
        await overwriteAllMovies(with: curr)
    }
    
    func overwriteAllMovies(with newMovies: [Movie]) async {
        guard let url = URL(string: endpoint) else { return }
        struct Payload: Codable { let action: String; let movies: [Movie] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONEncoder().encode(Payload(action: "overwrite", movies: newMovies))
            let _ = try await URLSession.shared.data(for: req)
            await MainActor.run { self.movies = newMovies }
        } catch { }
    }
    
    func cleanupDatabase() async { await fetchMovies(force: true) }
    
    private func saveToCache(_ list: [Movie]) {
        try? JSONEncoder().encode(list).write(to: cacheFileURL)
    }
    
    private func loadFromCache() {
        if let d = try? Data(contentsOf: cacheFileURL),
           let l = try? JSONDecoder().decode([Movie].self, from: d) {
            self.movies = l
        }
    }
}

@Observable
final class AboutManager {
    var featuresUpdate: String = "Loading..."
    var coreValue: String = "Loading..."
    var isFetching: Bool = false
    func fetchAboutContent() async { }
}

// Admin / auto-update functionality has been removed for production builds.
// AutoUpdateManager and related admin workflows are deprecated and handled by the web admin panel.

@Observable
final class MovieLikeManager {
    var likeCount = 0
    var isLikedByCurrentUser = false
    
    private let db = Firestore.firestore(database: "ai-studio-c2f1ae4d-bb2b-48e7-876b-c75e5b54a82f")
    private var listener: ListenerRegistration?
    
    func startListening(for chineseTitle: String) {
        stopListening()
        
        let cleanTitle = chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        
        listener = db.collection("reviews_v2").document(cleanTitle).collection("likes")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error = error {
                    print("Like listener error: \(error.localizedDescription)")
                    return
                }
                
                let documents = snapshot?.documents ?? []
                let currentUID = Auth.auth().currentUser?.uid
                
                Task { @MainActor in
                    self.likeCount = documents.count
                    self.isLikedByCurrentUser = currentUID.map { uid in
                        documents.contains(where: { $0.documentID == uid })
                    } ?? false
                }
            }
    }
    
    func stopListening() {
        listener?.remove()
        listener = nil
        likeCount = 0
        isLikedByCurrentUser = false
    }
    
    func toggleLike(for chineseTitle: String) async {
        guard let user = Auth.auth().currentUser else { return }
        
        let cleanTitle = chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = db.collection("reviews_v2").document(cleanTitle).collection("likes").document(user.uid)
        
        do {
            if isLikedByCurrentUser {
                try await ref.delete()
            } else {
                try await ref.setData([
                    "uid": user.uid,
                    "updatedAt": FieldValue.serverTimestamp()
                ])
            }
        } catch {
            print("Toggle like failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Native Ticketing Models (Aligned with Web Team Spec)
struct Showtime: Identifiable, Codable, Hashable {
    let id: String
    let movieId: String
    let movieTitle: String
    let cinemaName: String
    let startTime: String      // "HH:mm" (24h)
    let showDate: String       // "yyyy-MM-dd"
    let hallName: String
    let version: String        // 2D / 3D / IMAX / 4DX ...
    let buyUrl: String
    let remainingSeats: Int?
    let price: Double?
    let source: String         // Wmoov / HKMovie / Enjoy
    let updatedAt: String      // ISO 8601
    
    var isLowSeats: Bool {
        if let s = remainingSeats { return s > 0 && s < 10 }
        return false
    }
    
    var isSoldOut: Bool {
        (remainingSeats ?? 1) <= 0
    }
    
    var versionBadges: [String] {
        let upper = version.uppercased()
        var badges: [String] = []
        if upper.contains("IMAX") { badges.append("IMAX") }
        if upper.contains("4DX") { badges.append("4DX") }
        if upper.contains("3D") && !upper.contains("4DX") { badges.append("3D") }
        if upper.contains("DOLBY") { badges.append("Dolby") }
        return badges
    }
}

@Observable
final class ShowtimeManager {
    var showtimes: [Showtime] = []
    var isLoading = false
    
    // Keep the named DB consistent with the rest of the app. If web writes to
    // the default DB, change this to Firestore.firestore().
    private let db = Firestore.firestore(database: "ai-studio-c2f1ae4d-bb2b-48e7-876b-c75e5b54a82f")
    private var listener: ListenerRegistration?
    
    /// Distinct show dates sorted ascending (yyyy-MM-dd).
    var availableDates: [String] {
        Array(Set(showtimes.map(\.showDate))).sorted()
    }
    
    /// Returns showtimes for a date, grouped by cinema name and sorted by startTime.
    func grouped(for date: String) -> [(cinema: String, items: [Showtime])] {
        let sameDay = showtimes.filter { $0.showDate == date }
        let grouped = Dictionary(grouping: sameDay, by: { $0.cinemaName })
        return grouped
            .map { (cinema: $0.key, items: $0.value.sorted { $0.startTime < $1.startTime }) }
            .sorted { $0.cinema < $1.cinema }
    }
    
    func startListening(for movie: Movie) {
        stopListening()
        isLoading = true
        
        listener = db.collection("showtimes")
            .whereField("movieId", isEqualTo: movie.id)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                
                if let error {
                    print("Showtimes fetch error: \(error.localizedDescription)")
                    Task { @MainActor in self.isLoading = false }
                    return
                }
                
                let docs = snapshot?.documents ?? []
                let todayStr = Self.todayHKString()
                
                let items: [Showtime] = docs.compactMap { doc in
                    let d = doc.data()
                    let showDate = d["showDate"] as? String ?? ""
                    
                    // Drop past dates (defensive; web should already clean up).
                    guard showDate >= todayStr else { return nil }
                    
                    return Showtime(
                        id: doc.documentID,
                        movieId: d["movieId"] as? String ?? "",
                        movieTitle: d["movieTitle"] as? String ?? "",
                        cinemaName: d["cinemaName"] as? String ?? "",
                        startTime: d["startTime"] as? String ?? "",
                        showDate: showDate,
                        hallName: d["hallName"] as? String ?? "",
                        version: d["version"] as? String ?? "",
                        buyUrl: d["buyUrl"] as? String ?? "",
                        remainingSeats: d["remainingSeats"] as? Int,
                        price: (d["price"] as? Double) ?? (d["price"] as? Int).map(Double.init),
                        source: d["source"] as? String ?? "",
                        updatedAt: d["updatedAt"] as? String ?? ""
                    )
                }
                
                Task { @MainActor in
                    self.showtimes = items
                    self.isLoading = false
                }
            }
    }
    
    func stopListening() {
        listener?.remove()
        listener = nil
        showtimes = []
    }
    
    private static func todayHKString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Hong_Kong")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

// MARK: - Enums & Config
enum DisplayStyle: String, CaseIterable, Identifiable {
    case list, grid, coverflow
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        case .coverflow: return "rectangle.stack"
        }
    }
    
    func loc(_ l: AppLanguage) -> String {
        switch self {
        case .list: return l.t("列表", "列表", "List")
        case .grid: return l.t("網格", "网格", "Grid")
        case .coverflow: return l.t("海報牆", "海报墙", "Coverflow")
        }
    }
}

enum MovieFilter: String, CaseIterable, Identifiable {
    case all, canto, chi, other
    var id: String { rawValue }
    
    func loc(_ l: AppLanguage) -> String {
        switch self {
        case .all: return l.filterAll
        case .canto: return l.filterCanto
        case .chi: return l.filterChi
        case .other: return l.filterOther
        }
    }
    
    func matches(_ movieType: String?) -> Bool {
        let type = (movieType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch self {
        case .all: return true
        case .canto: return type == "CANTO"
        case .chi: return type == "CHI"
        case .other: return type == "OTHER"
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case traditional = "繁", simplified = "簡", english = "英"
    var id: String { rawValue }
    
    var localeIdentifier: String {
        switch self {
        case .traditional: return "zh-HK"
        case .simplified: return "zh-CN"
        case .english: return "en-US"
        }
    }
    
    func t(_ trad: String, _ simp: String, _ eng: String) -> String {
        switch self {
        case .traditional: return trad
        case .simplified: return simp
        case .english: return eng
        }
    }
    
    var tabHome: String { t("首頁", "首页", "Home") }
    var tabCountdown: String { t("倒數", "倒数", "Countdown") }
    var tabPremium: String { t("尊享", "尊享", "Premium") }
    var tabMy: String { t("我的", "我的", "My") }
    var textWelcome: String { t("歡迎回來", "欢迎回来", "Welcome back") }
    var toggleWatched: String { t("已觀看", "已观看", "Watched") }
    var toggleSkipped: String { t("不想看", "不想看", "Skip") }
    var sectionCompleted: String { t("已處理", "已处理", "Completed") }
    var toggleIncludeOtherMovies: String { t("包含華語片", "包含港产片", "Incl. Chinese") }
    var filterAll: String { t("全部", "全部", "All") }
    var filterCanto: String { t("港產片", "港产片", "Cantonese") }
    var filterChi: String { t("華語片", "华语片", "Chinese") }
    var filterOther: String { t("外語片", "外语片", "Foreign") }
    var buttonWatchTrailer: String { t("觀看預告", "观看预告", "Trailer") }
    var buttonViewShowtimes: String { t("查看場次", "查看场次", "Tickets") }
    var sectionReviews: String { t("電影評論", "电影评论", "Reviews") }
    var labelNoReviews: String { t("暫無評論", "暂无评论", "No reviews yet") }
    var textMyAccountDesc: String { t("帳戶資訊", "帐户资讯", "Account Info") }
    var buttonLogout: String { t("登出", "登出", "Logout") }
    var buttonLogin: String { t("登入", "登录", "Login") }
    var labelSearching: String { t("搜尋中...", "搜索中...", "Searching...") }
    var labelNoAchievements: String { t("暫無成就", "暂无成就", "No Achievements") }
    var optAchievements: String { t("成就獎章", "成就奖章", "Achievements") }
    var labelArchive: String { t("已落畫", "已落画", "Archive") }
    var buttonAdminLogin: String { t("管理員登入", "管理员登录", "Admin Login") }
    var promptEnterPassword: String { t("輸入密碼", "输入密码", "Enter Password") }
    var promptPasswordPlaceholder: String { t("密碼", "密码", "Password") }
    var buttonSubmit: String { t("提交", "提交", "Submit") }
    var buttonCancel: String { t("取消", "取消", "Cancel") }
    var buttonConfirm: String { t("確認", "确认", "Confirm") }
    var buttonOK: String { t("確定", "确定", "OK") }
    var titleEditProfile: String { t("編輯個人檔案", "编辑个人档案", "Edit Profile") }
    var labelDisplayName: String { t("顯示名稱", "显示名称", "Display Name") }
    var labelAvatarURL: String { t("頭像連結 (imgbb)", "头像链接 (imgbb)", "Avatar URL (imgbb)") }
    var buttonSave: String { t("儲存", "储存", "Save") }
    var sectionAbout: String { t("關於", "关于", "About") }
    var buttonFeaturesUpdate: String { t("功能更新", "功能更新", "Updates") }
    var buttonCoreValue: String { t("我們的核心價值", "我们的核心价值", "Values") }
    var buttonPrivacyPolicy: String { t("私隱政策", "隐私政策", "Privacy") }
    var urgentMovieTitle: String { t("本週推介", "本周推介", "Featured") }
    var toggleAutoUpdate: String { t("啟用自動更新", "启用自动更新", "Auto Update") }
    var buttonDiscoverMovies: String { t("發掘港產片", "发掘港产片", "Discover") }
    var buttonAutoFillUrls: String { t("自動填寫連結", "自动填写链接", "Auto Fill Links") }
    var buttonAutoFillTrailers: String { t("自動填寫預告", "自动填写预告", "Auto Fill Trailers") }
    var buttonCleanup: String { t("清理重複電影", "清理重复", "Cleanup") }
    var buttonForceUpdate: String { t("強制更新", "强制更新", "Force Update") }
    var labelSearchMovie: String { t("搜尋電影名稱...", "搜索电影名称...", "Search...") }
    var labelConfirmAdd: String { t("確認新增", "确认新增", "Add") }

    func textDaysUntil(days: Int) -> String { t("距離上映還有 \(days) 天", "距離上映還有 \(days) 天", "\(days) days until screening") }
    func textDaysSince(days: Int) -> String { days == 0 ? t("今日上映", "今日上映", "Screening Today") : t("已上映 \(days) 天", "已上映 \(days) 天", "Screening for \(days) days") }
    func textWatchedProgress(w: Int, t: Int) -> String { self.t("已觀看: \(w) / \(t)", "已观看: \(w) / \(t)", "Watched: \(w) / \(t)") }
    func labelWordCount(count: Int) -> String { t("字數: \(count) / 20", "字数: \(count) / 20", "Words: \(count) / 20") }
    func textUpdateFrequency(days: Int) -> String { t("頻率：\(days) 天", "频率：\(days) 天", "Update Frequency: \(days) Days") }
}

// MARK: - Safari In-App Browser Wrapper
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.preferredControlTintColor = UIColor.systemBlue
        return vc
    }
    
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - UI Components
struct MovieRowView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(WatchedManager.self) private var watched
    let movie: Movie
    
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: movie.posterURL ?? "")) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.3) }
                .frame(width: 70, height: 100)
                .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(movie.chineseTitle)
                    .font(.headline)
                    .strikethrough(watched.isSkipped(movie.chineseTitle))
                
                Text(movie.englishTitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                Text(movie.isScreeningNow ? lang.textDaysSince(days: movie.daysSinceScreening) : lang.textDaysUntil(days: movie.daysUntilScreening))
                    .font(.caption)
                    .bold()
                    .foregroundColor(movie.isScreeningNow ? movie.urgencyColor : .blue)
            }
        }
        .padding(.vertical, 4)
    }
}

struct WatchedItemRowView: View {
    let item: WatchedItem
    
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: item.posterUrl)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.gray.opacity(0.3)
                    .overlay(Image(systemName: "film").foregroundColor(.gray))
            }
            .frame(width: 70, height: 100)
            .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.movieTitle)
                    .font(.headline)
                    .lineLimit(2)
                
                Text(item.watchedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct MovieGridItemView: View {
    let movie: Movie
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: URL(string: movie.posterURL ?? "")) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.3) }
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(movie.chineseTitle)
                    .font(.caption)
                    .bold()
                    .lineLimit(1)
                Text(movie.englishTitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct MovieCoverflowItemView: View {
    let movie: Movie
    
    var body: some View {
        AsyncImage(url: URL(string: movie.posterURL ?? "")) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.3) }
            .aspectRatio(2 / 3, contentMode: .fit)
            .cornerRadius(16)
            .shadow(radius: 10)
            .padding()
    }
}

struct AlphabetIndexView: View {
    let letters: [String]
    let onSelect: (String) -> Void
    
    var body: some View {
        VStack(spacing: 2) {
            ForEach(letters, id: \.self) { letter in
                Button(letter) {
                    onSelect(letter)
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.secondary)
                .frame(width: 18, height: 14)
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

struct MovieCollectionView: View {
    @AppStorage("displayStyle") private var displayStyle: DisplayStyle = .grid
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(WatchedManager.self) private var watched
    
    let movies: [Movie]
    let searchText: String
    
    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func matchesSearch(_ movie: Movie) -> Bool {
        guard !normalizedSearchText.isEmpty else { return true }
        return movie.englishTitle.localizedCaseInsensitiveContains(normalizedSearchText) ||
               movie.chineseTitle.localizedCaseInsensitiveContains(normalizedSearchText)
    }
    
    private var activeMovies: [Movie] {
        movies.filter { !watched.isWatched($0.chineseTitle) && !watched.isSkipped($0.chineseTitle) && matchesSearch($0) }
    }
    
    private var firstMovieIDByLetter: [String: String] {
        var result: [String: String] = [:]
        for movie in activeMovies {
            if result[movie.englishIndexLetter] == nil {
                result[movie.englishIndexLetter] = movie.id
            }
        }
        return result
    }
    
    private var availableLetters: [String] {
        firstMovieIDByLetter.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs < rhs
        }
    }
    
    private var showsAlphabetIndex: Bool {
        normalizedSearchText.isEmpty && availableLetters.count > 1
    }
    
    var body: some View {
        switch displayStyle {
        case .list:
            ScrollViewReader { proxy in
                ZStack(alignment: .trailing) {
                    List {
                        ForEach(activeMovies) { movie in
                            NavigationLink(destination: MovieDetailView(movie: movie)) {
                                MovieRowView(movie: movie)
                            }
                            .id(movie.id)
                        }
                    }
                    .listStyle(.plain)
                    
                    if showsAlphabetIndex {
                        AlphabetIndexView(letters: availableLetters) { letter in
                            if let id = firstMovieIDByLetter[letter] {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                        .padding(.trailing, 4)
                    }
                }
            }
            
        case .grid:
            ScrollViewReader { proxy in
                ZStack(alignment: .trailing) {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                            ForEach(activeMovies) { movie in
                                NavigationLink(destination: MovieDetailView(movie: movie)) {
                                    MovieGridItemView(movie: movie)
                                }
                                .buttonStyle(.plain)
                                .id(movie.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 20)
                    }
                    .padding(.top, 8)
                    
                    if showsAlphabetIndex {
                        AlphabetIndexView(letters: availableLetters) { letter in
                            if let id = firstMovieIDByLetter[letter] {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                        .padding(.trailing, 4)
                    }
                }
            }
            
        case .coverflow:
            ScrollViewReader { proxy in
                ZStack(alignment: .trailing) {
                    ScrollView {
                        ForEach(activeMovies) { movie in
                            NavigationLink(destination: MovieDetailView(movie: movie)) {
                                MovieCoverflowItemView(movie: movie)
                            }
                            .buttonStyle(.plain)
                            .id(movie.id)
                        }
                    }
                    
                    if showsAlphabetIndex {
                        AlphabetIndexView(letters: availableLetters) { letter in
                            if let id = firstMovieIDByLetter[letter] {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                        .padding(.trailing, 4)
                    }
                }
            }
        }
    }
}

struct TrailerPreviewCardView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(\.openURL) private var openURL
    let trailerURL: String?
    
    private var playableURL: URL? {
        guard let trailerURL, let url = URL(string: trailerURL) else { return nil }
        return url
    }
    
    private var thumbnailURL: URL? {
        guard let id = youtubeID(from: trailerURL) else { return nil }
        return URL(string: "https://img.youtube.com/vi/\(id)/hqdefault.jpg")
    }
    
    var body: some View {
        Group {
            if let playableURL {
                Button { openURL(playableURL) } label: {
                    ZStack {
                        Group {
                            if let thumbnailURL {
                                AsyncImage(url: thumbnailURL) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.25) }
                            } else {
                                ZStack {
                                    Color.black.opacity(0.88)
                                    Image(systemName: "play.rectangle.fill")
                                        .font(.system(size: 54))
                                        .foregroundColor(.white.opacity(0.88))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 320)
                        .clipped()
                        
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.black.opacity(0.10),
                                Color.black.opacity(0.55)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        
                        VStack {
                            HStack {
                                Label(lang.buttonWatchTrailer, systemImage: "play.rectangle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.white.opacity(0.94))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.black.opacity(0.30))
                                    .clipShape(Capsule())
                                Spacer()
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 16)
                            
                            Spacer()
                            
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 72))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                                .padding(.bottom, 54)
                        }
                    }
                }
                .buttonStyle(.plain)
            } else {
                ZStack {
                    Rectangle().fill(Color(.secondarySystemBackground))
                    VStack(spacing: 8) {
                        Image(systemName: "play.slash")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text(lang.t("暫無預告片", "暂无预告片", "No trailer available"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 260)
            }
        }
    }
    
    private func youtubeID(from rawURL: String?) -> String? {
        guard let rawURL,
              let url = URL(string: rawURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        
        let host = url.host?.lowercased() ?? ""
        
        if host.contains("youtu.be") { return url.pathComponents.dropFirst().first }
        if host.contains("youtube.com") {
            if let v = components.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty { return v }
            let parts = url.pathComponents
            if let i = parts.firstIndex(of: "embed"), i + 1 < parts.count { return parts[i + 1] }
            if let i = parts.firstIndex(of: "shorts"), i + 1 < parts.count { return parts[i + 1] }
        }
        return nil
    }
}

struct DetailChipView: View {
    let text: String
    let systemImage: String
    let tint: Color
    
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(tint.opacity(0.12))
            )
    }
}

struct DetailFactCardView: View {
    let iconName: String
    let tint: Color
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: iconName)
                .font(.headline)
                .foregroundColor(tint)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

struct MovieHeroSummaryView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    let movie: Movie
    
    private var daysText: String {
        movie.isScreeningNow ? lang.textDaysSince(days: movie.daysSinceScreening) : lang.textDaysUntil(days: movie.daysUntilScreening)
    }
    
    private var accentColor: Color {
        movie.isScreeningNow ? movie.urgencyColor : .blue
    }
    
    private var movieTypeText: String? {
        switch movie.normalizedMovieType {
        case "CANTO": return lang.filterCanto
        case "CHI": return lang.filterChi
        case "OTHER": return lang.filterOther
        default: return nil
        }
    }
    
    private var runningTimeText: String? {
        guard let movieLengthMinute = movie.movieLengthMinute else { return nil }
        return lang.t("\(movieLengthMinute) 分鐘", "\(movieLengthMinute) 分钟", "\(movieLengthMinute) min")
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            AsyncImage(url: URL(string: movie.posterURL ?? "")) {
                $0.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.gray.opacity(0.22))
                    .overlay(
                        Image(systemName: "film")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                    )
            }
            .frame(width: 128, height: 192)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 18, y: 12)
            
            VStack(alignment: .leading, spacing: 12) {
                Text(movie.chineseTitle)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                
                Text(movie.englishTitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack(spacing: 8) {
                    DetailChipView(
                        text: daysText,
                        systemImage: movie.isScreeningNow ? "sparkles" : "calendar.badge.clock",
                        tint: accentColor
                    )
                    
                    if let movieTypeText {
                        DetailChipView(
                            text: movieTypeText,
                            systemImage: "film.stack",
                            tint: .orange
                        )
                    }
                }
                
                HStack(spacing: 8) {
                    if let ageLimit = movie.ageLimit?.trimmingCharacters(in: .whitespacesAndNewlines), !ageLimit.isEmpty {
                        DetailChipView(
                            text: ageLimit,
                            systemImage: "checkmark.shield",
                            tint: .purple
                        )
                    }
                    
                    if let runningTimeText {
                        DetailChipView(
                            text: runningTimeText,
                            systemImage: "clock",
                            tint: .teal
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.12), radius: 22, y: 12)
        .padding(.horizontal)
    }
}

struct MovieMetadataRowView: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MovieDetailsSectionView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    let movie: Movie
    
    private var releaseDateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: lang.localeIdentifier)
        formatter.dateStyle = .medium
        return formatter.string(from: movie.releaseDate)
    }
    
    private var runningTimeText: String? {
        guard let minutes = movie.movieLengthMinute else { return nil }
        return lang.t("\(minutes) 分鐘", "\(minutes) 分钟", "\(minutes) min")
    }
    
    private var trimmedIntroText: String? {
        let text = movie.introText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
    
    private var trimmedDistributor: String? {
        let text = movie.distributor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
    
    private var trimmedAgeLimit: String? {
        let text = movie.ageLimit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
    
    private var trimmedCastText: String? {
        let text = movie.castText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let intro = trimmedIntroText {
                VStack(alignment: .leading, spacing: 12) {
                    Label(lang.t("簡介", "简介", "Introduction"), systemImage: "text.alignleft")
                        .font(.headline)
                    
                    Text(intro)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            }
            
            VStack(alignment: .leading, spacing: 14) {
                Label(lang.t("電影資料", "电影资料", "Movie Details"), systemImage: "info.circle")
                    .font(.headline)
                
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    if let distributor = trimmedDistributor {
                        DetailFactCardView(
                            iconName: "shippingbox.fill",
                            tint: .orange,
                            title: lang.t("發行", "发行", "Distributor"),
                            value: distributor
                        )
                    }
                    
                    if let runningTimeText {
                        DetailFactCardView(
                            iconName: "clock.fill",
                            tint: .blue,
                            title: lang.t("片長", "片长", "Running Time"),
                            value: runningTimeText
                        )
                    }
                    
                    if let ageLimit = trimmedAgeLimit {
                        DetailFactCardView(
                            iconName: "checkmark.shield.fill",
                            tint: .purple,
                            title: lang.t("級別", "级别", "Age Rating"),
                            value: ageLimit
                        )
                    }
                    
                    DetailFactCardView(
                        iconName: "calendar",
                        tint: .green,
                        title: lang.t("上映日期", "上映日期", "Release Date"),
                        value: releaseDateText
                    )
                }
            }
            
            if let cast = trimmedCastText {
                VStack(alignment: .leading, spacing: 12) {
                    Label(lang.t("演員", "演员", "Cast"), systemImage: "person.2.fill")
                        .font(.headline)
                    
                    Text(cast)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            }
        }
        .padding(.horizontal)
    }
}

struct LanguageSwitcherView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    var body: some View {
        Menu {
            Picker("Language", selection: $lang) {
                ForEach(AppLanguage.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            HStack { Image(systemName: "globe"); Text(lang.rawValue) }
        }
    }
}

struct DisplayStyleSwitcherView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @AppStorage("displayStyle") private var style: DisplayStyle = .grid
    var body: some View {
        Menu {
            Picker("Style", selection: $style) {
                ForEach(DisplayStyle.allCases) {
                    Label($0.loc(lang), systemImage: $0.iconName).tag($0)
                }
            }
        } label: {
            Image(systemName: style.iconName)
        }
    }
}

// MARK: - Tab Views
struct HomeView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @AppStorage("movieFilter") private var filter: MovieFilter = .canto
    @Environment(MovieManager.self) private var manager
    @State private var searchText = ""
    
    var filtered: [Movie] {
        let filteredMovies = manager.movies
            .filter { $0.isScreeningNow }
            .filter { filter.matches($0.movieType) }
            .filter { !($0.isOffCinema ?? false) }
        
        if filter == .all {
            return filteredMovies.sorted {
                if $0.movieTypeSortPriority != $1.movieTypeSortPriority {
                    return $0.movieTypeSortPriority < $1.movieTypeSortPriority
                }
                return $0.releaseDate > $1.releaseDate
            }
        }
        
        return filteredMovies
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(lang.filterAll, selection: $filter) {
                    ForEach(MovieFilter.allCases) { filter in
                        Text(filter.loc(lang)).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                MovieCollectionView(
                    movies: filtered,
                    searchText: searchText
                )
                .refreshable { await manager.fetchMovies(force: true) }
            }
            .navigationTitle(lang.tabHome)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    DisplayStyleSwitcherView()
                    LanguageSwitcherView()
                }
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: lang.labelSearchMovie
        )
    }
}

struct CountdownView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @AppStorage("movieFilter") private var filter: MovieFilter = .canto
    @Environment(MovieManager.self) private var manager
    @State private var searchText = ""
    
    var filtered: [Movie] {
        let filteredMovies = manager.movies
            .filter { !$0.isScreeningNow }
            .filter { filter.matches($0.movieType) }
            .filter { !($0.isOffCinema ?? false) }
        
        if filter == .all {
            return filteredMovies.sorted {
                if $0.movieTypeSortPriority != $1.movieTypeSortPriority {
                    return $0.movieTypeSortPriority < $1.movieTypeSortPriority
                }
                return $0.releaseDate < $1.releaseDate
            }
        }
        
        return filteredMovies.sorted { $0.releaseDate < $1.releaseDate }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(lang.filterAll, selection: $filter) {
                    ForEach(MovieFilter.allCases) { filter in
                        Text(filter.loc(lang)).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                MovieCollectionView(
                    movies: filtered,
                    searchText: searchText
                )
                .refreshable { await manager.fetchMovies(force: true) }
            }
            .navigationTitle(lang.tabCountdown)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    DisplayStyleSwitcherView()
                    LanguageSwitcherView()
                }
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: lang.labelSearchMovie
        )
    }
}

struct ArchiveMoviesView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(MovieManager.self) private var manager
    @State private var searchText = ""
    
    var archivedMovies: [Movie] {
        manager.movies.filter { $0.isOffCinema == true }
            .sorted { $0.releaseDate > $1.releaseDate }
    }
    
    var body: some View {
        MovieCollectionView(
            movies: archivedMovies,
            searchText: searchText
        )
        .navigationTitle(lang.labelArchive)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: lang.labelSearchMovie)
    }
}

struct PremiumView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(WatchedManager.self) private var watchedManager
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AchievementsView()
                    } label: {
                        Label(lang.optAchievements, systemImage: "trophy.fill")
                            .foregroundColor(.orange)
                    }
                    
                    NavigationLink {
                        WatchedMoviesView()
                    } label: {
                        HStack {
                            Label("Blackboxy", systemImage: "film.fill")
                                .foregroundColor(.blue)
                            Spacer()
                            // Use watchedItems.count to stay in sync with what
                            // WatchedMoviesView actually renders.
                            Text("\(watchedManager.watchedItems.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    NavigationLink {
                        ArchiveMoviesView()
                    } label: {
                        HStack {
                            Label(lang.labelArchive, systemImage: "archivebox.fill")
                                .foregroundColor(.brown)
                        }
                    }
                }
                
                Section {
                    NavigationLink {
                        SkippedMoviesView()
                    } label: {
                        HStack {
                            Label(lang.toggleSkipped, systemImage: "xmark.circle.fill")
                                .foregroundColor(.gray)
                            Spacer()
                            Text("\(watchedManager.skippedMovieTitles.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(lang.tabPremium)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    LanguageSwitcherView()
                }
            }
        }
    }
}

struct WatchedMoviesView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(WatchedManager.self) private var watchedManager
    
    @State private var showAddSheet = false
    @State private var showBulkImportSheet = false
    
    var body: some View {
        List {
            ForEach(watchedManager.watchedItems) { item in
                WatchedItemRowView(item: item)
            }
            .onDelete { indexSet in
                for idx in indexSet {
                    let item = watchedManager.watchedItems[idx]
                    watchedManager.deleteWatchedItem(item.movieTitle)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Blackboxy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showBulkImportSheet = true
                } label: {
                    Image(systemName: "doc.text.viewfinder")
                }
                
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay {
            if watchedManager.watchedItems.isEmpty {
                ContentUnavailableView(lang.t("暫無電影", "暂无电影", "No Movies"), systemImage: "film")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ManualAddWatchedMovieView()
        }
        .sheet(isPresented: $showBulkImportSheet) {
            BulkTextImportView()
        }
    }
}

struct BulkTextImportView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(\.dismiss) private var dismiss
    
    @State private var inputText = ""
    @State private var showProcessor = false
    @State private var queries: [String] = []
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(lang.t("你可以直接使用 iPhone 截圖中的「原況文字」(Live Text) 功能拷貝電影清單，然後貼上到這裡。每行一套電影。", "你可以直接使用 iPhone 截图中的「原况文字」(Live Text) 功能拷贝电影清单，然后贴上到这里。每行一套电影。", "You can use iPhone's built-in Live Text to copy a list of movies from a screenshot and paste it here. Put one movie per line."))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                TextEditor(text: $inputText)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
            }
            .padding()
            .navigationTitle(lang.t("匯入電影", "导入电影", "Import Movies"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(lang.buttonCancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(lang.t("分析", "分析", "Analyze")) {
                        queries = inputText.components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        
                        if !queries.isEmpty {
                            showProcessor = true
                        }
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationDestination(isPresented: $showProcessor) {
                ImportProcessorView(queries: queries)
            }
        }
    }
}

struct ImportProcessorView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(\.dismiss) private var dismiss
    @Environment(WatchedManager.self) private var watchedManager
    
    let queries: [String]
    @State private var selections: [ImportedMovieSelection] = []
    @State private var isProcessing = true
    
    var body: some View {
        List {
            if isProcessing {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(lang.t("正在搜尋...", "正在搜索...", "Searching..."))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 40)
            } else {
                ForEach($selections) { $selection in
                    ImportRowView(selection: $selection)
                }
                .onDelete { indexSet in
                    selections.remove(atOffsets: indexSet)
                }
            }
        }
        .navigationTitle(lang.t("確認匯入", "确认导入", "Confirm Import"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(lang.buttonConfirm) {
                    confirmAndSave()
                }
                .disabled(isProcessing || selections.filter { $0.selectedMovie != nil }.isEmpty)
            }
        }
        .task {
            await processQueries()
        }
    }
    
    private func processQueries() async {
        var results: [ImportedMovieSelection] = []
        for query in queries {
            var movie: TMDBMovie? = nil
            movie = await searchFirstTMDB(query: query)
            results.append(ImportedMovieSelection(extractedText: query, selectedMovie: movie, isSearching: false))
        }
        await MainActor.run {
            self.selections = results
            self.isProcessing = false
        }
    }
    
    private func searchFirstTMDB(query: String) async -> TMDBMovie? {
        let apiKey = "087fe585100b7b9441c86cc4f4094166"
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.themoviedb.org/3/search/movie?api_key=\(apiKey)&query=\(encodedQuery)&language=zh-HK") else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(TMDBResponse.self, from: data)
            return response.results.first
        } catch {
            return nil
        }
    }
    
    private func confirmAndSave() {
        for selection in selections {
            if let movie = selection.selectedMovie {
                watchedManager.addManualWatched(tmdbMovie: movie)
            }
        }
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = windowScene.windows.first?.rootViewController {
            root.dismiss(animated: true)
        }
    }
}

struct ImportRowView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Binding var selection: ImportedMovieSelection
    @State private var showSearch = false
    
    var body: some View {
        HStack(spacing: 12) {
            if let posterPath = selection.selectedMovie?.poster_path {
                AsyncImage(url: URL(string: "https://image.tmdb.org/t/p/w200\(posterPath)")) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.3)
                }
                .frame(width: 50, height: 75)
                .cornerRadius(4)
                .clipped()
            } else {
                Color.gray.opacity(0.3)
                    .frame(width: 50, height: 75)
                    .cornerRadius(4)
                    .overlay(Image(systemName: "film").foregroundColor(.gray))
            }
            
            VStack(alignment: .leading, spacing: 4) {
                if let movie = selection.selectedMovie {
                    Text(movie.title)
                        .font(.headline)
                    if let date = movie.release_date {
                        Text(date.prefix(4))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(lang.t("找不到結果", "找不到结果", "No Match Found"))
                        .font(.headline)
                        .foregroundColor(.red)
                    Text("\(lang.t("搜尋關鍵字:", "搜索关键字:", "Search:")) \(selection.extractedText)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
            
            Button(lang.t("修改", "修改", "Edit")) {
                showSearch = true
            }
            .buttonStyle(.bordered)
        }
        .sheet(isPresented: $showSearch) {
            ImportManualSearchView(selection: $selection)
        }
    }
}

struct ImportManualSearchView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: ImportedMovieSelection
    
    @State private var searchText = ""
    @State private var searchResults: [TMDBMovie] = []
    @State private var isSearching = false
    private let apiKey = "087fe585100b7b9441c86cc4f4094166"
    
    var body: some View {
        NavigationStack {
            List(searchResults, id: \.id) { tmdbMovie in
                HStack {
                    if let posterPath = tmdbMovie.poster_path {
                        AsyncImage(url: URL(string: "https://image.tmdb.org/t/p/w200\(posterPath)")) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.gray.opacity(0.3)
                        }
                        .frame(width: 40, height: 60)
                        .cornerRadius(4)
                    } else {
                        Color.gray.opacity(0.3)
                            .frame(width: 40, height: 60)
                            .cornerRadius(4)
                            .overlay(Image(systemName: "film").foregroundColor(.gray))
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tmdbMovie.title)
                            .font(.headline)
                        if let date = tmdbMovie.release_date {
                            Text(date.prefix(4))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Button(lang.t("選擇", "选择", "Select")) {
                        selection.selectedMovie = tmdbMovie
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .searchable(text: $searchText, prompt: lang.labelSearchMovie)
            .onChange(of: searchText) { _, newValue in
                Task { await performSearch(query: newValue) }
            }
            .navigationTitle(lang.t("搜尋電影", "搜索电影", "Search Movie"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(lang.buttonCancel) { dismiss() }
                }
            }
            .onAppear {
                searchText = selection.extractedText
            }
            .overlay {
                if isSearching {
                    ProgressView()
                } else if searchResults.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView(lang.t("沒有結果", "没有结果", "No Results"), systemImage: "magnifyingglass")
                }
            }
        }
    }
    
    private func performSearch(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        
        isSearching = true
        defer { isSearching = false }
        
        guard let encodedQuery = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.themoviedb.org/3/search/movie?api_key=\(apiKey)&query=\(encodedQuery)&language=zh-HK") else {
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(TMDBResponse.self, from: data)
            await MainActor.run {
                self.searchResults = response.results
            }
        } catch {
            print("Search error: \(error)")
        }
    }
}

struct ManualAddWatchedMovieView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WatchedManager.self) private var watchedManager
    
    @State private var searchText = ""
    @State private var searchResults: [TMDBMovie] = []
    @State private var isSearching = false
    
    private let apiKey = "087fe585100b7b9441c86cc4f4094166"
    
    var body: some View {
        NavigationStack {
            List(searchResults, id: \.id) { tmdbMovie in
                HStack {
                    if let posterPath = tmdbMovie.poster_path {
                        AsyncImage(url: URL(string: "https://image.tmdb.org/t/p/w200\(posterPath)")) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.gray.opacity(0.3)
                        }
                        .frame(width: 40, height: 60)
                        .cornerRadius(4)
                    } else {
                        Color.gray.opacity(0.3)
                            .frame(width: 40, height: 60)
                            .cornerRadius(4)
                            .overlay(Image(systemName: "film").foregroundColor(.gray))
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tmdbMovie.title)
                            .font(.headline)
                        if let date = tmdbMovie.release_date {
                            Text(date.prefix(4))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Button("Add") {
                        watchedManager.addManualWatched(tmdbMovie: tmdbMovie)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .searchable(text: $searchText, prompt: "Search movie name...")
            .onChange(of: searchText) { _, newValue in
                Task {
                    await performSearch(query: newValue)
                }
            }
            .navigationTitle("Add Watched Movie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if isSearching {
                    ProgressView()
                } else if searchResults.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView("No Results", systemImage: "magnifyingglass")
                }
            }
        }
    }
    
    private func performSearch(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        
        isSearching = true
        defer { isSearching = false }
        
        guard let encodedQuery = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.themoviedb.org/3/search/movie?api_key=\(apiKey)&query=\(encodedQuery)&language=zh-HK") else {
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(TMDBResponse.self, from: data)
            await MainActor.run {
                self.searchResults = response.results
            }
        } catch {
            print("Search error: \(error)")
        }
    }
}

struct SkippedMoviesView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(MovieManager.self) private var movieManager
    @Environment(WatchedManager.self) private var watchedManager
    
    var skippedMovies: [Movie] {
        movieManager.movies.filter { watchedManager.isSkipped($0.chineseTitle) }
            .sorted { $0.releaseDate > $1.releaseDate }
    }
    
    var body: some View {
        List {
            ForEach(skippedMovies) { movie in
                NavigationLink(destination: MovieDetailView(movie: movie)) {
                    MovieRowView(movie: movie)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(lang.toggleSkipped)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if skippedMovies.isEmpty {
                ContentUnavailableView(lang.t("暫無電影", "暂无电影", "No Movies"), systemImage: "film")
            }
        }
    }
}

struct MyProfileView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(AuthManager.self) private var auth
    @Environment(MovieManager.self) private var manager
    // AutoUpdateManager removed in production; admin workflows are migrated to web.
    
    @State private var isUnlocked = false
    @State private var showPwd = false
    @State private var pwd = ""
    @State private var showEditProfile = false
    @State private var showAuth = false
    
    // Account deletion state
    @State private var showDeleteConfirm = false
    @State private var showDeletePasswordPrompt = false
    @State private var deletePassword = ""
    @State private var isDeleting = false
    @State private var showDeleteError = false
    @State private var showDeleteSuccess = false
    
    private var isEmailOnlyUser: Bool {
        let providers = Set(auth.providerIDs)
        return providers.contains("password")
            && !providers.contains("apple.com")
            && !providers.contains("google.com")
    }
    
    var body: some View {
        NavigationStack {
            // admin auto-update manager removed
            List {
                Section {
                    if auth.isSignedIn {
                        HStack(spacing: 16) {
                            AsyncImage(url: URL(string: auth.currentUserPhoto)) { $0.resizable().scaledToFill() } placeholder: {
                                Image(systemName: "person.crop.circle.fill").resizable().foregroundColor(.gray.opacity(0.3))
                            }
                            .frame(width: 60, height: 60)
                            .clipShape(Circle())
                            
                            VStack(alignment: .leading) {
                                Text(auth.currentDisplayName).font(.headline)
                                Text(auth.displayEmail).font(.caption).foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button { showEditProfile = true } label: {
                                Image(systemName: "pencil.circle.fill").font(.title2).foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 8)
                        
                        Button(lang.buttonLogout) { auth.signOut() }
                            .foregroundColor(.red)
                    } else {
                        Button(lang.buttonLogin) { showAuth = true }
                    }
                } header: {
                    Text(lang.textMyAccountDesc)
                }
                
                // MARK: - Account Deletion (only when signed in)
                if auth.isSignedIn {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                if isDeleting {
                                    ProgressView()
                                        .padding(.trailing, 4)
                                }
                                Label(
                                    lang.t("刪除帳戶", "删除账户", "Delete Account"),
                                    systemImage: "trash.fill"
                                )
                            }
                        }
                        .disabled(isDeleting)
                    } footer: {
                        Text(lang.t(
                            "此操作將永久刪除你的帳戶、觀看紀錄及所有關聯資料，並無法還原。",
                            "此操作将永久删除你的账户、观看记录及所有关联数据，且无法还原。",
                            "This permanently deletes your account, watch history, and associated data. This cannot be undone."
                        ))
                    }
                }
                
                // Admin section removed for production; admin workflows moved to web.
            }
            .navigationTitle(lang.tabMy)
            .sheet(isPresented: $showEditProfile) { EditProfileView() }
            .sheet(isPresented: $showAuth) { AuthView() }
            .alert(lang.promptEnterPassword, isPresented: $showPwd) {
                SecureField(lang.promptPasswordPlaceholder, text: $pwd)
                Button(lang.buttonSubmit) {
                    if pwd == "admin" { isUnlocked = true }
                    pwd = ""
                }
            }
            // Step 1 of deletion: confirm
            .alert(
                lang.t("確認刪除帳戶？", "确认删除账户？", "Delete your account?"),
                isPresented: $showDeleteConfirm
            ) {
                Button(lang.buttonCancel, role: .cancel) {}
                Button(lang.t("刪除", "删除", "Delete"), role: .destructive) {
                    if isEmailOnlyUser {
                        showDeletePasswordPrompt = true
                    } else {
                        Task { await performDelete() }
                    }
                }
            } message: {
                Text(lang.t(
                    "此操作無法還原。你將需要再次驗證身份。",
                    "此操作无法还原。你将需要再次验证身份。",
                    "This action cannot be undone. You will be asked to verify your identity."
                ))
            }
            // Step 2 (email users only): password prompt for re-auth
            .alert(
                lang.t("輸入密碼以確認", "输入密码以确认", "Confirm your password"),
                isPresented: $showDeletePasswordPrompt
            ) {
                SecureField(lang.promptPasswordPlaceholder, text: $deletePassword)
                Button(lang.buttonCancel, role: .cancel) {
                    deletePassword = ""
                }
                Button(lang.t("刪除", "删除", "Delete"), role: .destructive) {
                    Task { await performDelete(password: deletePassword) }
                }
            } message: {
                Text(lang.t(
                    "為保護你的帳戶安全，請輸入密碼以確認刪除。",
                    "为保护你的账户安全，请输入密码以确认删除。",
                    "For security, please enter your password to confirm deletion."
                ))
            }
            // Error feedback
            .alert(
                lang.t("刪除失敗", "删除失败", "Deletion Failed"),
                isPresented: $showDeleteError,
                presenting: auth.errorMessage
            ) { _ in
                Button(lang.buttonOK, role: .cancel) {
                    auth.errorMessage = nil
                }
            } message: { message in
                Text(message)
            }
            // Success feedback
            .alert(
                lang.t("帳戶已刪除", "账户已删除", "Account Deleted"),
                isPresented: $showDeleteSuccess
            ) {
                Button(lang.buttonOK, role: .cancel) {}
            } message: {
                Text(lang.t(
                    "你的帳戶及相關資料已永久刪除。",
                    "你的账户及相关数据已永久删除。",
                    "Your account and associated data have been permanently deleted."
                ))
            }
        }
    }
    
    private func performDelete(password: String? = nil) async {
        isDeleting = true
        defer {
            isDeleting = false
            deletePassword = ""
        }
        
        let success = await auth.deleteAccount(emailPassword: password)
        
        if success {
            showDeleteSuccess = true
        } else {
            showDeleteError = true
        }
    }
}
// MARK: - Sub Views
struct MovieDetailView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(\.openURL) private var openURL
    @Environment(WatchedManager.self) private var watched
    @Environment(ReviewManager.self) private var reviewManager
    @Environment(AuthManager.self) private var auth
    
    let movie: Movie
    @State private var likeManager = MovieLikeManager()
    @State private var showShowtimesSheet = false
    
    private var shareText: String {
        var parts = ["\(movie.chineseTitle) / \(movie.englishTitle)"]
        parts.append(movie.isScreeningNow ? lang.textDaysSince(days: movie.daysSinceScreening) : lang.textDaysUntil(days: movie.daysUntilScreening))
        if let trailerURL = movie.trailerURL, !trailerURL.isEmpty { parts.append(trailerURL) }
        return parts.joined(separator: "\n")
    }
    
    private var likeCountText: String {
        lang.t("\(likeManager.likeCount) 個讚", "\(likeManager.likeCount) 个赞", "\(likeManager.likeCount) likes")
    }
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                topShowcase
                actionRow
                MovieDetailsSectionView(movie: movie)
                ReviewSection(movie: movie)
            }
            .padding(.bottom, 28)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(movie.chineseTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                }
                
                Button {
                    watched.toggleWatched(for: movie)
                } label: {
                    Image(systemName: watched.isWatched(movie.chineseTitle) ? "eye.fill" : "eye")
                        .foregroundStyle(watched.isWatched(movie.chineseTitle) ? .green : .primary)
                }
                
                Button {
                    watched.toggleSkipped(for: movie)
                } label: {
                    Image(systemName: watched.isSkipped(movie.chineseTitle) ? "xmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(watched.isSkipped(movie.chineseTitle) ? .gray : .primary)
                }
            }
        }
        .task(id: movie.id) {
            likeManager.startListening(for: movie.chineseTitle)
            reviewManager.startListening(for: movie.chineseTitle)
        }
        .onDisappear {
            likeManager.stopListening()
            reviewManager.stopListening()
        }
        .sheet(isPresented: $showShowtimesSheet) {
            ShowtimesSheetView(movie: movie)
        }
    }
    
    private var topShowcase: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                TrailerPreviewCardView(trailerURL: movie.trailerURL)
                LinearGradient(
                    colors: [
                        Color.orange.opacity(0.14),
                        Color(.systemGroupedBackground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 72)
            }
            
            MovieHeroSummaryView(movie: movie)
                .offset(y: 88)
        }
        .padding(.bottom, 88)
    }
    
    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await likeManager.toggleLike(for: movie.chineseTitle) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: likeManager.isLikedByCurrentUser ? "heart.fill" : "heart")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lang.t("喜歡", "喜欢", "Like"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(likeCountText)
                            .font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                }
                .foregroundColor(likeManager.isLikedByCurrentUser ? .pink : .primary)
                .frame(maxWidth: .infinity, minHeight: 64)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            }
            .buttonStyle(.plain)
            .disabled(!auth.isSignedIn)
            
            Button {
                showShowtimesSheet = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "ticket.fill")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lang.t("場次", "场次", "Tickets"))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.88))
                        Text(lang.buttonViewShowtimes)
                            .font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 64)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.blue.opacity(0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
            }
        }
        .padding(.horizontal)
        
        if !auth.isSignedIn {
            Text(lang.t("登入後可按讚", "登录后可点赞", "Sign in to like"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Showtimes Sheet (Aligned with Web Spec)
struct ShowtimesSheetView: View {
    let movie: Movie
    @State private var showtimeManager = ShowtimeManager()
    @State private var selectedDate: String = ""
    @State private var safariURL: IdentifiableURL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional

    private var dates: [String] { showtimeManager.availableDates }
    
    private var currentGrouping: [(cinema: String, items: [Showtime])] {
        guard !selectedDate.isEmpty else { return [] }
        return showtimeManager.grouped(for: selectedDate)
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if showtimeManager.isLoading && showtimeManager.showtimes.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text(lang.t("正在載入場次...", "正在加载场次...", "Loading Showtimes..."))
                            .foregroundColor(.secondary)
                    }
                } else if showtimeManager.showtimes.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        datePicker
                        List {
                            ForEach(currentGrouping, id: \.cinema) { group in
                                Section(header: Text(group.cinema)) {
                                    ForEach(group.items) { showtime in
                                        showtimeRow(showtime)
                                    }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                }
            }
            .navigationTitle(movie.chineseTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(lang.buttonCancel) { dismiss() }
                }
            }
            .onAppear {
                showtimeManager.startListening(for: movie)
            }
            .onChange(of: dates) { _, newDates in
                if selectedDate.isEmpty, let first = newDates.first {
                    selectedDate = first
                } else if !newDates.contains(selectedDate), let first = newDates.first {
                    selectedDate = first
                }
            }
            .onDisappear {
                showtimeManager.stopListening()
            }
            .sheet(item: $safariURL) { wrapper in
                SafariView(url: wrapper.url)
                    .ignoresSafeArea()
            }
        }
    }
    
    @ViewBuilder
    private var datePicker: some View {
        if dates.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dates, id: \.self) { date in
                        Button {
                            selectedDate = date
                        } label: {
                            Text(displayLabel(for: date))
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(selectedDate == date ? Color.blue : Color(.secondarySystemBackground))
                                )
                                .foregroundColor(selectedDate == date ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
        }
    }
    
    @ViewBuilder
    private func showtimeRow(_ showtime: Showtime) -> some View {
        Button {
            guard let url = URL(string: showtime.buyUrl) else { return }
            safariURL = IdentifiableURL(url: url)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(showtime.startTime)
                            .font(.headline.monospacedDigit())
                        
                        if !showtime.hallName.isEmpty {
                            Text(showtime.hallName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    HStack(spacing: 6) {
                        ForEach(showtime.versionBadges, id: \.self) { badge in
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.purple.opacity(0.15)))
                                .foregroundColor(.purple)
                        }
                        
                        if showtime.versionBadges.isEmpty && !showtime.version.isEmpty {
                            Text(showtime.version)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        if showtime.isSoldOut {
                            Text(lang.t("已售罄", "已售罄", "Sold Out"))
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.red.opacity(0.18)))
                                .foregroundColor(.red)
                        } else if showtime.isLowSeats {
                            Text(lang.t("極少量剩餘", "极少量剩余", "Few Seats Left"))
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.red.opacity(0.18)))
                                .foregroundColor(.red)
                        }
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    if let price = showtime.price {
                        Text(String(format: "$%.0f", price))
                            .font(.subheadline.weight(.semibold))
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
            .opacity(showtime.isSoldOut ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(showtime.isSoldOut || showtime.buyUrl.isEmpty)
    }
    
    private var emptyState: some View {
        ContentUnavailableView {
            Label(lang.t("暫無場次", "暂无场次", "No Showtimes Available"), systemImage: "ticket.slash")
        } description: {
            Text(lang.t("可能即將上映或已落畫，可嘗試於外部網站搜尋。", "可能即将上映或已落画，可尝试于外部网站搜索。", "May be upcoming or ended. Try searching on external sites."))
        } actions: {
            HStack {
                Button("WMOOV") { openLink(site: "wmoov.com") }
                Button("HKMovie6") { openLink(site: "hkmovie6.com") }
                Button("Enjoy Movie") { openLink(site: "enjoymovie.net") }
            }
            .buttonStyle(.bordered)
            .padding(.top)
        }
    }
    
    private func displayLabel(for dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Hong_Kong")
        guard let date = formatter.date(from: dateString) else { return dateString }
        
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Hong_Kong") ?? .current
        
        if cal.isDateInToday(date) { return lang.t("今日", "今日", "Today") }
        if cal.isDateInTomorrow(date) { return lang.t("明日", "明日", "Tomorrow") }
        
        let display = DateFormatter()
        display.locale = Locale(identifier: lang.localeIdentifier)
        display.timeZone = TimeZone(identifier: "Asia/Hong_Kong")
        display.dateFormat = lang == .english ? "EEE, MMM d" : "M月d日 (EEE)"
        return display.string(from: date)
    }
    
    private func openLink(site: String) {
        let query = movie.chineseTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var fallbackURLString = ""
        
        switch site {
        case "wmoov.com":
            fallbackURLString = movie.wmoovURL ?? "https://wmoov.com/search?q=\(query)"
        case "enjoymovie.net":
            fallbackURLString = movie.enjoymovieURL ?? "https://enjoymovie.net/search?q=\(query)"
        default:
            fallbackURLString = movie.hkmovieURL ?? "https://hkmovie6.com/"
        }
        
        if let url = URL(string: fallbackURLString) {
            safariURL = IdentifiableURL(url: url)
        }
    }
}

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct ReviewSection: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(ReviewManager.self) private var reviewManager
    @Environment(AuthManager.self) private var auth
    @Environment(WatchedManager.self) private var watchedManager
    
    let movie: Movie
    @State private var showComposer = false
    
    private var hasWatched: Bool {
        watchedManager.isWatched(movie.chineseTitle)
    }
    
    private var myReview: Review? {
        guard let uid = auth.user?.uid else { return nil }
        return reviewManager.reviews.first(where: { $0.userId == uid })
    }
    
    private var reviewCountText: String {
        lang.t(
            "\(reviewManager.reviews.count) 則評論",
            "\(reviewManager.reviews.count) 条评论",
            "\(reviewManager.reviews.count) reviews"
        )
    }
    
    private var averageRatingText: String? {
        if !hasWatched {
            return "5.0 / 5"
        }
        guard !reviewManager.reviews.isEmpty else { return nil }
        let total = reviewManager.reviews.reduce(0.0) { partial, review in
            partial + review.rating
        }
        let average = total / Double(reviewManager.reviews.count)
        return String(format: "%.1f / 5", average)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(lang.sectionReviews)
                        .font(.headline)
                    
                    HStack(spacing: 8) {
                        if let averageRatingText {
                            Label(averageRatingText, systemImage: "star.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.orange.opacity(0.12)))
                        }
                        
                        Text(reviewCountText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if auth.isSignedIn {
                    if hasWatched {
                        Button(myReview == nil ? lang.t("新增評論", "新增评论", "Add Review") : lang.t("編輯評論", "编辑评论", "Edit Review")) {
                            showComposer = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    } else {
                        Text(lang.t("標記已觀看以解鎖", "标记已观看以解锁", "Watch to unlock"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(lang.t("登入後可評論", "登录后可评论", "Sign in to review"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            
            if reviewManager.isFetching && reviewManager.reviews.isEmpty {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 120)
                    .overlay {
                        ProgressView()
                    }
                    .padding(.horizontal)
            } else if reviewManager.reviews.isEmpty {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 120)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "text.bubble")
                                .font(.title3)
                                .foregroundColor(.secondary)
                            Text(lang.labelNoReviews)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
            } else {
                ZStack {
                    VStack(spacing: 14) {
                        ForEach(reviewManager.reviews) { review in
                            ReviewRow(review: review)
                                .padding(.horizontal)
                        }
                    }
                    .blur(radius: hasWatched ? 0 : 8)
                    .allowsHitTesting(hasWatched)
                    
                    if !hasWatched {
                        VStack(spacing: 12) {
                            Image(systemName: "lock.fill")
                                .font(.largeTitle)
                                .foregroundColor(.primary)
                            
                            Text(lang.t("標記已觀看即可解鎖評論", "标记已观看即可解锁评论", "Mark as watched to unlock reviews"))
                                .font(.headline)
                                .multilineTextAlignment(.center)
                        }
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
                        .padding(.horizontal, 32)
                    }
                }
            }
        }
        .sheet(isPresented: $showComposer) {
            WriteReviewView(movie: movie, existingReview: myReview)
        }
    }
}

struct EditProfileView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var photo = ""
    @State private var item: PhotosPickerItem?
    
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Photo URL", text: $photo)
                PhotosPicker("Select Image", selection: $item)
            }
            .onAppear {
                name = auth.currentDisplayName
                photo = auth.currentUserPhoto
            }
            .toolbar {
                Button("Save") {
                    Task {
                        await auth.updateProfile(name: name, photo: photo)
                        dismiss()
                    }
                }
            }
        }
        .onChange(of: item) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let url = try? await auth.uploadToImgBB(data: data) {
                    photo = url
                }
            }
        }
    }
}

struct WriteReviewView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(AuthManager.self) private var auth
    @Environment(ReviewManager.self) private var reviewManager
    @Environment(\.dismiss) private var dismiss
    
    let movie: Movie
    let existingReview: Review?
    
    @State private var content = ""
    @State private var rating = 5
    @State private var isSaving = false
    @State private var errorMessage: String?
    
    private var wordCount: Int { reviewManager.calculateWordCount(in: content) }
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(movie.chineseTitle).font(.headline)
                Text(movie.englishTitle).font(.subheadline).foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 10) {
                    Text(lang.t("你的評分", "你的评分", "Your Rating"))
                        .font(.subheadline)
                        .bold()
                    
                    HStack(spacing: 10) {
                        ForEach(1...5, id: \.self) { value in
                            Button { rating = value } label: {
                                Image(systemName: value <= rating ? "star.fill" : "star")
                                    .font(.title2)
                                    .foregroundColor(.orange)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Text("\(rating)/5")
                            .font(.subheadline)
                            .bold()
                            .foregroundColor(.secondary)
                    }
                }
                
                TextEditor(text: $content)
                    .frame(minHeight: 220)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                
                HStack {
                    Text(lang.labelWordCount(count: wordCount))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle(existingReview == nil ? lang.t("新增評論", "新增评论", "Add Review") : lang.t("編輯評論", "编辑评论", "Edit Review"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(lang.buttonCancel) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(lang.buttonSave) {
                            Task { await saveReview() }
                        }
                        .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !auth.isSignedIn)
                    }
                }
            }
            .onAppear {
                content = existingReview?.content ?? ""
                rating = min(max(Int((existingReview?.rating ?? 5).rounded()), 1), 5)
            }
        }
    }
    
    private func saveReview() async {
        guard auth.isSignedIn else {
            errorMessage = lang.t("請先登入以撰寫評論。", "请先登录以撰写评论。", "Please sign in before writing a review.")
            return
        }
        
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = lang.t("評論內容不能為空。", "评论内容不能为空。", "Review content cannot be empty.")
            return
        }
        
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        
        do {
            try await reviewManager.upsertReview(chineseTitle: movie.chineseTitle, content: trimmed, rating: Double(rating))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DiscoverMoviesView: View { var body: some View { Text("Discover") } }
struct AddMovieView: View { var body: some View { Text("Add") } }

// MARK: - Main Application
struct ContentView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @State private var movieManager = MovieManager()
    @State private var watchedManager = WatchedManager()
    @State private var premiumManager = PremiumManager()
    @State private var authManager = AuthManager()
    @State private var reviewManager = ReviewManager()
    @State private var achievementManager = AchievementManager()
    // AutoUpdateManager removed; admin features handled on web.
    @State private var blockedUserManager = BlockedUserManager()
    
    var body: some View {
        TabView {
            HomeView().tabItem { Label(lang.tabHome, systemImage: "popcorn") }
            CountdownView().tabItem { Label(lang.tabCountdown, systemImage: "timer") }
            PremiumView().tabItem { Label(lang.tabPremium, systemImage: "star.fill") }
            MyProfileView().tabItem { Label(lang.tabMy, systemImage: "person.crop.circle") }
        }
        .environment(movieManager)
        .environment(watchedManager)
        .environment(premiumManager)
        .environment(authManager)
        .environment(reviewManager)
        .environment(blockedUserManager)
        .environment(achievementManager)
        .task { await movieManager.fetchMovies() }
        .task(id: authManager.user?.uid) {
            guard authManager.user != nil else {
                watchedManager.stopListening()
                return
            }
            watchedManager.startListening()
            await authManager.loadUserData(into: watchedManager, premium: premiumManager)
        }
    }
}

#Preview { ContentView() }
