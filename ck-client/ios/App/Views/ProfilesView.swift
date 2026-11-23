import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var settings: AppSettings
    @State private var editing: Profile?
    @State private var creating = false
    @State private var showImport = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.profiles) { p in
                    Button { editing = p } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(p.name).foregroundColor(Theme.text)
                                Spacer()
                                Text(p.isTLS ? "TLS" : "SSH")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Theme.primary.opacity(0.15)).foregroundColor(Theme.primary)
                                    .clipShape(Capsule())
                            }
                            Text("\(p.user) @ \(p.host):\(p.port)").font(.caption).foregroundColor(Theme.muted)
                        }
                    }
                    .listRowBackground(Theme.card)
                }
                .onDelete { idx in
                    for i in idx { store.delete(store.profiles[i].name) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Profiles")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showImport = true } label: { Label("Import from panel", systemImage: "square.and.arrow.down") }
                        Button { creating = true } label: { Label("New profile", systemImage: "plus") }
                    } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .overlay {
                if store.profiles.isEmpty {
                    VStack(spacing: 10) {
                        Text("No profiles").font(.headline).foregroundColor(Theme.text)
                        Text("Copy an account link in the CK.VPN panel, then tap Import.")
                            .font(.footnote).foregroundColor(Theme.muted).multilineTextAlignment(.center)
                        Button("Import from panel") { showImport = true }
                            .buttonStyle(BigButtonStyle(color: Theme.primary, foreground: Color(hex: 0x031116)))
                            .frame(maxWidth: 260)
                    }.padding()
                }
            }
        }
        .sheet(item: $editing) { p in ProfileEditView(original: p) }
        .sheet(isPresented: $creating) { ProfileEditView(original: nil) }
        .sheet(isPresented: $showImport) { ImportView(initialText: nil) }
    }
}
