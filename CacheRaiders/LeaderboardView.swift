import SwiftUI

// MARK: - Leaderboard View
struct LeaderboardView: View {
    @State private var leaderboard: [TopFinder] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "trophy.fill")
                    .foregroundColor(.yellow)
                    .font(.title2)
                Text("Leaderboard")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button(action: {
                    loadLeaderboard()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.blue)
                }
                .disabled(isLoading)
            }
            .padding()
            .background(Color(.systemBackground))
            
            Divider()
            
            // Content
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading leaderboard...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        loadLeaderboard()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if leaderboard.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "trophy")
                        .font(.largeTitle)
                        .foregroundColor(.gray)
                    Text("No finds yet")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Be the first to find an object!")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(leaderboard.enumerated()), id: \.offset) { (index, finder) in
                            LeaderboardRow(
                                rank: index + 1,
                                userName: finder.display_name ?? finder.user_id,
                                count: finder.find_count,
                                isTopThree: index < 3
                            )
                        }
                    }
                    .padding()
                    .padding(.leading, 8) // Extra padding for rank circles
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            loadLeaderboard()
        }
    }
    
    private func loadLeaderboard() {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        // Run on background thread to avoid blocking UI
        Task {
            do {
                let stats = try await APIService.shared.getStats()
                self.leaderboard = stats.top_finders
                self.isLoading = false
            } catch {
                self.errorMessage = "Failed to load leaderboard: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
}

// MARK: - Leaderboard Row
struct LeaderboardRow: View {
    let rank: Int
    let userName: String
    let count: Int
    let isTopThree: Bool
    
    var body: some View {
        HStack(spacing: 16) {
            // Rank badge
            ZStack {
                Circle()
                    .fill(rankBadgeColor)
                    .frame(width: 44, height: 44)

                if rank == 1 {
                    Image(systemName: "crown.fill")
                        .foregroundColor(.yellow)
                        .font(.title3)
                } else {
                    Text("\(rank)")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(rankTextColor)
                }
            }
            .padding(.leading, 4) // Ensure circle isn't clipped
            
            // User name
            VStack(alignment: .leading, spacing: 4) {
                Text(userName)
                    .font(.body)
                    .fontWeight(isTopThree ? .semibold : .regular)
                    .foregroundColor(.primary)
                
                if isTopThree {
                    Text(rankLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Count
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
                Text("\(count)")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: isTopThree ? Color.yellow.opacity(0.2) : Color.black.opacity(0.05), radius: isTopThree ? 8 : 4, x: 0, y: 2)
    }
    
    private var rankBadgeColor: Color {
        switch rank {
        case 1: return Color.yellow.opacity(0.3)
        case 2: return Color.gray.opacity(0.3)
        case 3: return Color.orange.opacity(0.3)
        default: return Color.gray.opacity(0.2)
        }
    }
    
    private var rankTextColor: Color {
        switch rank {
        case 1, 2, 3: return .black
        default: return .primary
        }
    }
    
    private var rankLabel: String {
        switch rank {
        case 1: return "🥇 Champion"
        case 2: return "🥈 Runner-up"
        case 3: return "🥉 Third Place"
        default: return ""
        }
    }
}

#Preview {
    LeaderboardView()
}










