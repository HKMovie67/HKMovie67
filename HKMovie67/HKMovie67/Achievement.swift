//
//  Achievement.swift
//  HKMovie67
//

import Foundation
import Observation
import SwiftUI

struct Achievement: Identifiable, Codable {
    let id: String
    let name: String
    let imageURL: String
    let condition: String
}

@Observable
final class AchievementManager {
    var achievements: [Achievement] = []
    var isFetching = false
    private let googleSheetEndpoint = "https://docs.google.com/spreadsheets/d/16vWVMOZ2MPsECMIS5tKDh9yXr-fgt9jjxJ2w_tM4G2c/gviz/tq?tqx=out:json&gid=1201228851"
    
    func fetchAchievements() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        
        do {
            guard let url = URL(string: googleSheetEndpoint) else { return }
            let (data, _) = try await URLSession.shared.data(from: url)
            
            var jsonString = String(data: data, encoding: .utf8) ?? ""
            if let startRange = jsonString.range(of: "{", options: .literal),
               let endRange = jsonString.range(of: ");", options: .backwards) {
                jsonString = String(jsonString[startRange.lowerBound..<endRange.lowerBound])
            }
            
            guard let jsonData = jsonString.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let table = root["table"] as? [String: Any],
                  let rows = table["rows"] as? [[String: Any]] else { return }
            
            var imgIndex = 0
            var nameIndex = 1
            var conditionIndex = 2
            
            if let cols = table["cols"] as? [[String: Any]] {
                for (i, col) in cols.enumerated() {
                    let label = (col["label"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    
                    if label.contains("img") || label.contains("image") {
                        imgIndex = i
                    } else if label.contains("name") {
                        nameIndex = i
                    } else if label.contains("condition") {
                        conditionIndex = i
                    }
                }
            }
            
            var decoded: [Achievement] = []
            
            for (rowIndex, row) in rows.enumerated() {
                guard let cells = row["c"] as? [Any?] else { continue }
                
                func cellString(at index: Int) -> String {
                    guard index < cells.count,
                          let cell = cells[index] as? [String: Any] else { return "" }
                    
                    if let v = cell["v"] as? String { return v }
                    if let v = cell["v"] { return "\(v)" }
                    return ""
                }
                
                let name = cellString(at: nameIndex)
                let imageURL = cellString(at: imgIndex)
                let condition = cellString(at: conditionIndex)
                
                if !name.isEmpty {
                    decoded.append(
                        Achievement(
                            id: "achievement-\(rowIndex)",
                            name: name,
                            imageURL: imageURL,
                            condition: condition
                        )
                    )
                }
            }
            
            await MainActor.run {
                self.achievements = decoded
            }
        } catch {
            print("Achievement fetch error: \(error)")
        }
    }
    
    // Evaluation logic using Natural Language parsing for exact movie names marked with 《 》
    func calculateProgress(
        for achievement: Achievement,
        allMovies: [Movie],
        watchedTitles: Set<String>,
        skippedTitles: Set<String>
    ) -> (current: Int, target: Int) {
        let condition = achievement.condition
        let lowerCondition = condition.lowercased()
        
        // 1. Extract titles between 《 and 》
        let bracketedTitles = extractBracketedTitles(from: condition)
        
        // Extract a number if present (e.g. "Watch 3 movies from...")
        let digits = condition.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        let extractedNumber = Int(digits)
        
        if !bracketedTitles.isEmpty {
            // We have specific movies mentioned in 《 》 marks.
            // Match these titles against our database
            var watchedMatches = 0
            
            for title in bracketedTitles {
                let matches = allMovies.filter { movie in
                    movie.chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines) == title ||
                    movie.englishTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title.lowercased()
                }
                
                // If any movie entry matching this title is watched, count this title as satisfied
                if matches.contains(where: { watchedTitles.contains($0.chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                    watchedMatches += 1
                }
            }
            
            // If the text says "Watch 2 of 《A》, 《B》, 《C》", target is 2.
            // Otherwise, target is the count of items listed in brackets.
            let target = min(extractedNumber ?? bracketedTitles.count, bracketedTitles.count)
            return (min(watchedMatches, target), target)
        }
        
        // 2. Fallback: Category matching if no specific 《 》 markers were found
        let isSkip =
            lowerCondition.contains("skip") ||
            lowerCondition.contains("不想看") ||
            lowerCondition.contains("略過") ||
            lowerCondition.contains("略过") ||
            lowerCondition.contains("跳過") ||
            lowerCondition.contains("跳过")
        
        let isCanto =
            lowerCondition.contains("canto") ||
            lowerCondition.contains("港產") ||
            lowerCondition.contains("港产") ||
            lowerCondition.contains("粵") ||
            lowerCondition.contains("粤")
        
        let isChi =
            lowerCondition.contains("chi") ||
            lowerCondition.contains("華語") ||
            lowerCondition.contains("华语") ||
            lowerCondition.contains("國語") ||
            lowerCondition.contains("国语")
        
        let target = extractedNumber ?? 1
        let current: Int
        
        if isSkip {
            current = skippedTitles.count
        } else if isCanto {
            current = allMovies.filter {
                watchedTitles.contains($0.chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines)) && $0.movieType == "CANTO"
            }.count
        } else if isChi {
            current = allMovies.filter {
                watchedTitles.contains($0.chineseTitle.trimmingCharacters(in: .whitespacesAndNewlines)) && $0.movieType == "CHI"
            }.count
        } else {
            // Default to total watched count
            current = watchedTitles.count
        }
        
        return (min(current, target), target)
    }
    
    private func extractBracketedTitles(from text: String) -> [String] {
        var titles: [String] = []
        let components = text.components(separatedBy: "《")
        
        // Start from 1 because index 0 is the text before the first 《
        for i in 1..<components.count {
            let sub = components[i]
            if let endRange = sub.range(of: "》") {
                let title = String(sub[..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    titles.append(title)
                }
            }
        }
        
        return titles
    }
}

// MARK: - Achievement Card View
struct AchievementCardView: View {
    let achievement: Achievement
    let movies: [Movie]
    let watchedTitles: Set<String>
    let skippedTitles: Set<String>
    let manager: AchievementManager
    
    private var stats: (current: Int, target: Int) {
        manager.calculateProgress(
            for: achievement,
            allMovies: movies,
            watchedTitles: watchedTitles,
            skippedTitles: skippedTitles
        )
    }
    
    private var unlocked: Bool {
        stats.current >= stats.target
    }
    
    private var progressPercent: CGFloat {
        guard stats.target > 0 else { return 0 }
        return CGFloat(stats.current) / CGFloat(stats.target)
    }
    
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                AsyncImage(url: URL(string: achievement.imageURL)) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    ZStack {
                        Color.gray.opacity(0.1)
                        Image(systemName: "trophy.fill")
                            .foregroundColor(.gray.opacity(0.4))
                            .font(.title)
                    }
                }
                .frame(width: 70, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 15))
                
                if !unlocked {
                    RoundedRectangle(cornerRadius: 15)
                        .fill(Color.black.opacity(0.4))
                    
                    Image(systemName: "lock.fill")
                        .foregroundColor(.white.opacity(0.8))
                        .font(.title3)
                }
            }
            .frame(width: 70, height: 70)
            .overlay(
                RoundedRectangle(cornerRadius: 15)
                    .stroke(unlocked ? Color.orange : Color.clear, lineWidth: 2)
            )
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(achievement.name)
                        .font(.headline)
                        .foregroundColor(unlocked ? .primary : .secondary)
                    
                    Spacer()
                    
                    if unlocked {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.orange)
                    }
                }
                
                Text(achievement.condition)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                
                VStack(alignment: .trailing, spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(.systemFill))
                                .frame(height: 6)
                            
                            Capsule()
                                .fill(unlocked ? Color.orange : Color.blue)
                                .frame(width: geo.size.width * progressPercent, height: 6)
                        }
                    }
                    .frame(height: 6)
                    
                    Text("\(stats.current) / \(stats.target)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(18)
        .opacity(unlocked ? 1.0 : 0.8)
    }
}

// MARK: - Achievements View
struct AchievementsView: View {
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional
    @Environment(WatchedManager.self) private var watchedManager
    @Environment(MovieManager.self) private var movieManager
    @Environment(AchievementManager.self) private var achievementManager
    
    private var watchedSummaryText: String {
        lang.t(
            "已觀看 \(watchedManager.watchedMovieTitles.count) 部電影",
            "已观看 \(watchedManager.watchedMovieTitles.count) 部电影",
            "\(watchedManager.watchedMovieTitles.count) movies watched"
        )
    }
    
    var body: some View {
        content
            .navigationTitle(lang.optAchievements)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if achievementManager.achievements.isEmpty {
                    await achievementManager.fetchAchievements()
                }
            }
            .refreshable {
                await achievementManager.fetchAchievements()
            }
    }
    
    @ViewBuilder
    private var content: some View {
        if achievementManager.isFetching && achievementManager.achievements.isEmpty {
            loadingView
        } else if achievementManager.achievements.isEmpty {
            emptyView
        } else {
            achievementsListView
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(lang.labelSearching)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var emptyView: some View {
        ContentUnavailableView(lang.labelNoAchievements, systemImage: "trophy")
    }
    
    private var achievementsListView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lang.optAchievements)
                            .font(.title2)
                            .bold()
                        
                        Text(watchedSummaryText)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top)
                
                ForEach(achievementManager.achievements) { achievement in
                    AchievementCardView(
                        achievement: achievement,
                        movies: movieManager.movies,
                        watchedTitles: watchedManager.watchedMovieTitles,
                        skippedTitles: watchedManager.skippedMovieTitles,
                        manager: achievementManager
                    )
                    .padding(.horizontal)
                }
            }
            .padding(.bottom, 30)
        }
    }
}
