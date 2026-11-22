import SwiftUI

/// Create profiles from what the CK.VPN panel gives: an ssh:// link, a list, base64, or the
/// subscription URL (typed/pasted, or scanned from the QR code of the subscription page).
struct ImportView: View {
    var initialText: String?
    @EnvironmentObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var detected: [ImportedProfile] = []
    @State private var manual = ""
    @State private var busy = false
    @State private var error = ""
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Copy an account link in the CK.VPN panel, or scan the QR code of its subscription page.")
                        .font(.subheadline).foregroundColor(Theme.muted)

                    PasteButton(payloadType: String.self) { strings in
                        if let s = strings.first { run(s) }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.roundedRectangle(radius: 15))
                    .tint(Theme.primary)
                    .frame(maxWidth: .infinity, minHeight: 50)

                    Button { showScanner = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                        .buttonStyle(BigButtonStyle(color: Theme.card, foreground: Theme.text))

                    HStack {
                        TextField("…or paste a link here", text: $manual)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(10).background(Theme.input).clipShape(RoundedRectangle(cornerRadius: 10))
                        Button("Read") { run(manual) }.disabled(manual.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if busy { ProgressView().frame(maxWidth: .infinity) }
                    if !error.isEmpty { Text(error).font(.footnote).foregroundColor(Theme.error) }

                    if !detected.isEmpty {
                        Text("DETECTED").font(.caption).foregroundColor(Theme.muted)
                        ForEach(Array(detected.enumerated()), id: \.offset) { _, d in
                            Card {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(d.name).font(.headline).foregroundColor(Theme.text)
                                        Spacer()
                                        Text(d.transport == "tls" ? "TLS" : "SSH").font(.caption2.bold())
                                            .padding(.horizontal, 7).padding(.vertical, 2)
                                            .background(Theme.primary.opacity(0.15)).foregroundColor(Theme.primary).clipShape(Capsule())
                                    }
                                    Text("\(d.user) @ \(d.host):\(d.port ?? 22)").font(.caption).foregroundColor(Theme.muted)
                                    if let sni = d.sni, !sni.isEmpty { Text("SNI: \(sni)").font(.caption).foregroundColor(Theme.muted) }
                                }
                            }
                        }
                        Button {
                            store.add(detected)
                            dismiss()
                        } label: { Text("Import \(detected.count) profile(s)") }
                            .buttonStyle(BigButtonStyle(color: Theme.primary, foreground: Color(hex: 0x031116)))
                    }

                    Text("Supports ssh:// links, link lists, base64 lists and https://HOST:2053/s/… subscription links.")
                        .font(.caption).foregroundColor(Theme.muted)
                }
                .padding(18)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Import profile")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showScanner) {
                ZStack(alignment: .topTrailing) {
                    QRScannerView(onCode: { code in showScanner = false; run(code) },
                                  onFail: { msg in showScanner = false; error = msg })
                        .ignoresSafeArea()
                    Button("Close") { showScanner = false }.padding().buttonStyle(.borderedProminent)
                }
            }
            .onAppear { if let t = initialText, detected.isEmpty { run(t) } }
        }
    }

    private func run(_ text: String) {
        error = ""
        detected = []
        busy = true
        Task {
            do { detected = try await store.importText(text) }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
