import SwiftUI

@main
struct CKClientApp: App {
    @StateObject private var store = ProfileStore()
    @StateObject private var vpn = VPNManager()
    @StateObject private var settings = AppSettings()
    @State private var pendingImport: String?

    var body: some Scene {
        WindowGroup {
            RootView(pendingImport: $pendingImport)
                .environmentObject(store)
                .environmentObject(vpn)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .tint(Theme.primary)
                // ckclient://import?link=<url-encoded ssh:// link or subscription URL>
                .onOpenURL { url in
                    guard url.scheme == "ckclient",
                          let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          let link = comps.queryItems?.first(where: { $0.name == "link" })?.value else { return }
                    pendingImport = link
                }
        }
    }
}

struct RootView: View {
    @Binding var pendingImport: String?
    @EnvironmentObject var store: ProfileStore
    @State private var tab = 0
    @State private var showImport = false

    var body: some View {
        TabView(selection: $tab) {
            HomeView().tabItem { Label("Home", systemImage: "power.circle.fill") }.tag(0)
            ProfilesView().tabItem { Label("Profiles", systemImage: "list.bullet") }.tag(1)
            LogView().tabItem { Label("Log", systemImage: "text.alignleft") }.tag(2)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(3)
        }
        .onChange(of: pendingImport) { value in
            if value != nil { showImport = true }
        }
        .sheet(isPresented: $showImport, onDismiss: { pendingImport = nil }) {
            ImportView(initialText: pendingImport)
        }
    }
}
