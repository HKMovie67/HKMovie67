//
//  TMDBService.swift
//  HKMovie67
//

import Foundation

// MARK: - TMDB API Response Models

private struct TMDBSearchResponse: Codable {
    let results: [TMDBSearchResult]
}

private struct TMDBSearchResult: Codable {
    let id: Int
    let title: String?
    let original_title: String?
    let release_date: String?
    let poster_path: String?
    let original_language: String?
    let popularity: Double?
}

private struct TMDBVideosResponse: Codable {
    let results: [TMDBVideo]
}

private struct TMDBVideo: Codable {
    let id: String
    let key: String
    let site: String
    let type: String             // "Trailer", "Teaser", "Clip", etc.
    let official: Bool?
    let iso_639_1: String?
    let published_at: String?
}

// MARK: - TMDBService

actor TMDBService {
    static let shared = TMDBService()

    private let apiKey = "087fe585100b7b9441c86cc4f4094166"
    private let posterBase = "https://image.tmdb.org/t/p/w500"

    /// In-memory cache keyed by movieId to avoid re-hitting TMDB within a session.
    private var cache: [String: TMDBEnrichment] = [:]

    struct TMDBEnrichment: Codable, Equatable {
        let posterURL: String?
        let trailerURL: String?
    }

    // MARK: - Disk Cache

    private var cacheFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tmdbCache.json")
    }

    private func loadDiskCache() {
        guard cache.isEmpty,
              let data = try? Data(contentsOf: cacheFileURL),
              let decoded = try? JSONDecoder().decode([String: TMDBEnrichment].self, from: data)
        else { return }
        cache = decoded
    }

    private func persistDiskCache() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheFileURL)
    }

    // MARK: - Public API

    /// Returns poster + trailer URLs for a movie. Results are cached per `movie.id`.
    /// Only fields that are missing on the input movie are fetched.
    func enrichment(for movie: Movie) async -> TMDBEnrichment {
        loadDiskCache()

        // Short-circuit if cached.
        if let cached = cache[movie.id] {
            return cached
        }

        // Nothing to fetch.
        let needsPoster = (movie.posterURL?.isEmpty ?? true)
        let needsTrailer = (movie.trailerURL?.isEmpty ?? true)
        guard needsPoster || needsTrailer else {
            let e = TMDBEnrichment(posterURL: movie.posterURL, trailerURL: movie.trailerURL)
            cache[movie.id] = e
            return e
        }

        // 1. Find the best TMDB match.
        guard let match = await bestMatch(for: movie) else {
            let e = TMDBEnrichment(posterURL: movie.posterURL, trailerURL: movie.trailerURL)
            cache[movie.id] = e
            persistDiskCache()
            return e
        }

        // 2. Build poster URL.
        var posterURL = movie.posterURL
        if needsPoster, let path = match.poster_path, !path.isEmpty {
            posterURL = posterBase + path
        }

        // 3. Fetch trailer if needed.
        var trailerURL = movie.trailerURL
        if needsTrailer {
            trailerURL = await fetchTrailerURL(tmdbId: match.id, preferredLanguage: match.original_language)
        }

        let result = TMDBEnrichment(posterURL: posterURL, trailerURL: trailerURL)
        cache[movie.id] = result
        persistDiskCache()
        return result
    }

    // MARK: - Search

    private func bestMatch(for movie: Movie) async -> TMDBSearchResult? {
        let type = (movie.movieType ?? "").uppercased()
        let isChineseFilm = (type == "CANTO" || type == "CHI")

        // Ordered list of (query, language) attempts.
        var attempts: [(String, String)] = []
        if isChineseFilm {
            attempts.append((movie.chineseTitle, "zh-HK"))
            attempts.append((movie.englishTitle, "en-US"))
        } else {
            attempts.append((movie.englishTitle, "en-US"))
            attempts.append((movie.chineseTitle, "zh-HK"))
        }

        let calendar = Calendar.current
        let targetYear = calendar.component(.year, from: movie.releaseDate)

        for (query, language) in attempts {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let results = await search(query: trimmed, language: language, year: targetYear)
            if let best = pickBest(results: results, targetYear: targetYear) {
                return best
            }
        }

        return nil
    }

    private func search(query: String, language: String, year: Int?) async -> [TMDBSearchResult] {
        guard var components = URLComponents(string: "https://api.themoviedb.org/3/search/movie") else { return [] }
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "include_adult", value: "false")
        ]
        if let year {
            items.append(URLQueryItem(name: "year", value: "\(year)"))
        }
        components.queryItems = items
        guard let url = components.url else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(TMDBSearchResponse.self, from: data)
            return decoded.results
        } catch {
            print("TMDB search failed for '\(query)' (\(language)): \(error.localizedDescription)")
            return []
        }
    }

    private func pickBest(results: [TMDBSearchResult], targetYear: Int) -> TMDBSearchResult? {
        guard !results.isEmpty else { return nil }

        func year(of result: TMDBSearchResult) -> Int? {
            guard let ds = result.release_date, ds.count >= 4 else { return nil }
            return Int(ds.prefix(4))
        }

        // Prefer within ±1 year, then closest, then highest popularity.
        let sorted = results.sorted { a, b in
            let ay = year(of: a).map { abs($0 - targetYear) } ?? Int.max
            let by = year(of: b).map { abs($0 - targetYear) } ?? Int.max
            if ay != by { return ay < by }
            return (a.popularity ?? 0) > (b.popularity ?? 0)
        }

        if let top = sorted.first,
           let ty = year(of: top),
           abs(ty - targetYear) <= 1 {
            return top
        }

        // Fallback: most popular match when year data is missing/mismatched.
        return sorted.first
    }

    // MARK: - Trailer

    private func fetchTrailerURL(tmdbId: Int, preferredLanguage: String?) async -> String? {
        // Try preferred language first (e.g. zh), then English, then default.
        var languagesToTry: [String?] = []
        if let lang = preferredLanguage, !lang.isEmpty {
            // Map ISO 639-1 to a TMDB-style locale.
            if lang.hasPrefix("zh") {
                languagesToTry.append("zh-HK")
                languagesToTry.append("zh-CN")
            } else {
                languagesToTry.append("\(lang)-US")
            }
        }
        languagesToTry.append("en-US")
        languagesToTry.append(nil)

        for language in languagesToTry {
            if let url = await fetchTrailer(tmdbId: tmdbId, language: language) {
                return url
            }
        }
        return nil
    }

    private func fetchTrailer(tmdbId: Int, language: String?) async -> String? {
        guard var components = URLComponents(string: "https://api.themoviedb.org/3/movie/\(tmdbId)/videos") else { return nil }
        var items = [URLQueryItem(name: "api_key", value: apiKey)]
        if let language {
            items.append(URLQueryItem(name: "language", value: language))
        }
        components.queryItems = items
        guard let url = components.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(TMDBVideosResponse.self, from: data)
            return pickBestVideo(from: decoded.results)
        } catch {
            print("TMDB videos failed for id \(tmdbId): \(error.localizedDescription)")
            return nil
        }
    }

    private func pickBestVideo(from videos: [TMDBVideo]) -> String? {
        let youtube = videos.filter { $0.site.lowercased() == "youtube" }
        guard !youtube.isEmpty else { return nil }

        func score(_ v: TMDBVideo) -> Int {
            var s = 0
            switch v.type.lowercased() {
            case "trailer": s += 100
            case "teaser":  s += 60
            case "clip":    s += 20
            default:        s += 0
            }
            if v.official == true { s += 25 }
            return s
        }

        let ranked = youtube.sorted { score($0) > score($1) }
        guard let best = ranked.first else { return nil }
        return "https://www.youtube.com/watch?v=\(best.key)"
    }
}
