import SwiftUI
import UIKit

/// Settings for Stroniarz Voice (STR-1281): handsfree base URL, token pasted
/// from the clipboard straight into the Keychain, and a /ping test.
struct VoiceSettingsView: View {

    @State private var baseURL = HandsfreeSettings.baseURLString
    @State private var hasToken = HandsfreeSettings.token != nil
    @State private var thinkingCue = HandsfreeSettings.thinkingCue
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                TextField("https://…ts.net:8444", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { HandsfreeSettings.baseURLString = baseURL }
            } header: {
                Text("Adres Maca")
            } footer: {
                Text("Usługa handsfree w tailnecie (tailscale serve na :8444).")
            }

            Section {
                HStack {
                    Text("Token")
                    Spacer()
                    Text(hasToken ? "zapisany w Keychain" : "brak")
                        .foregroundStyle(hasToken ? Color.green : Color.subtleText)
                }
                Button("Wklej token ze schowka") { pasteToken() }
                if hasToken {
                    Button("Usuń token", role: .destructive) {
                        HandsfreeSettings.token = nil
                        hasToken = false
                        status = nil
                    }
                }
            } footer: {
                Text("Na Macu: install_handsfree.sh --copy kopiuje token; Uniwersalny schowek przenosi go tutaj. Token nie jest wyświetlany.")
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("Test połączenia")
                        if testing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(testing)
                if let status {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.white)
                }
            }

            Section {
                Toggle("Mów „Myślę”, gdy Mac liczy", isOn: $thinkingCue)
                    .onChange(of: thinkingCue) { _, value in HandsfreeSettings.thinkingCue = value }
                Button("Wyślij ustawienia na zegarek") {
                    HandsfreeSettings.baseURLString = baseURL
                    status = VoiceRelay.pushConfigToWatch()
                        ? "Wysłane. Zegarek użyje ich, gdy nie widzi iPhone'a (wymaga publicznego adresu)."
                        : "Zegarek niedostępny albo brak tokenu."
                }
            } header: {
                Text("Eksperymentalne")
            } footer: {
                Text("Zegarek domyślnie pyta przez iPhone'a. Bezpośrednio połączy się tylko z adresem publicznym (Funnel).")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Stroniarz Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { HandsfreeSettings.baseURLString = baseURL }
    }

    private func pasteToken() {
        guard let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              pasted.count >= 24, !pasted.contains(" ") else {
            status = "W schowku nie ma tokenu."
            return
        }
        HandsfreeSettings.token = pasted
        UIPasteboard.general.string = ""
        hasToken = HandsfreeSettings.token != nil
        status = hasToken ? "Token zapisany." : "Nie udało się zapisać tokenu."
    }

    private func test() async {
        HandsfreeSettings.baseURLString = baseURL
        testing = true
        status = await HandsfreeClient.fromSettings().ping().spoken
        testing = false
    }
}

#Preview {
    NavigationStack { VoiceSettingsView() }
}
