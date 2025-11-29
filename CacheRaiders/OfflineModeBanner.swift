import SwiftUI

/// Offline Mode Banner - Displays offline status and pending sync count
struct OfflineModeBanner: View {
    @ObservedObject var offlineManager = OfflineModeManager.shared
    @State private var showBanner: Bool = false
    
    var body: some View {
        Group {
            if offlineManager.isOfflineMode {
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "wifi.slash")
                            .foregroundColor(.white)
                            .font(.system(size: 14))
                        
                        Text(offlineManager.statusMessage)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        if offlineManager.pendingSyncCount > 0 {
                            Text("\(offlineManager.pendingSyncCount) pending")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(
                            colors: [Color.orange, Color.red.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                }
                .transition(.move(edge: .top))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showBanner)
                .onAppear {
                    showBanner = true
                }
                .onDisappear {
                    showBanner = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OfflineModeEnabled"))) { _ in
            withAnimation {
                showBanner = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OfflineModeDisabled"))) { _ in
            withAnimation {
                showBanner = false
            }
        }
    }
}

/// Online Status Banner - Shows when coming back online
struct OnlineStatusBanner: View {
    @ObservedObject var offlineManager = OfflineModeManager.shared
    @State private var showBanner: Bool = false
    @State private var bannerMessage: String = ""
    
    var body: some View {
        Group {
            if showBanner && !offlineManager.isOfflineMode {
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "wifi")
                            .foregroundColor(.white)
                            .font(.system(size: 14))
                        
                        Text(bannerMessage.isEmpty ? "Back online!" : bannerMessage)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(
                            colors: [Color.green, Color.green.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                }
                .transition(.move(edge: .top))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showBanner)
                .onAppear {
                    // Auto-hide after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation {
                            showBanner = false
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OfflineModeDisabled"))) { notification in
            if let userInfo = notification.userInfo,
               let message = userInfo["message"] as? String {
                bannerMessage = message
            } else {
                bannerMessage = "Back online!"
            }
            
            withAnimation {
                showBanner = true
            }
            
            // Auto-hide after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    showBanner = false
                }
            }
        }
    }
}

/// Combined Offline/Online Banner View
struct NetworkStatusBanner: View {
    var body: some View {
        VStack(spacing: 0) {
            OnlineStatusBanner()
            OfflineModeBanner()
        }
    }
}

