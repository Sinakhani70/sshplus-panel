import SwiftUI

struct LogView: View {
    @EnvironmentObject var vpn: VPNManager

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(vpn.log.isEmpty ? String(localized: "The log appears here while the VPN is connected.") : vpn.log)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .textSelection(.enabled)
            }
            .background(Theme.bg)
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: vpn.log.isEmpty ? "CK Client log is empty" : vpn.log) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
    }
}
