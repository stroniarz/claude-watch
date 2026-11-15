import SwiftUI

/// Kolory Orki: ciemny watchOS, niebieski akcent (jak podgląd zegarka w panelu).
enum OrkaTheme {
    static let accent = Color(hex: "1E9EDC")
    static let accentText = Color(hex: "74C8F3")
    static let amber = Color(hex: "F4C97F")
    static let green = Color(hex: "8FE0B3")
    static let red = Color(hex: "FF7A6E")
    static let muted = Color(hex: "A9BBCF")
    static let tile = Color(hex: "0E1A27")
}

/// Ekran główny appki: liczniki panelu Orki i „Mów do Orki” (STR-1463).
struct OrkaHomeView: View {
    @ObservedObject var model: OrkaModel
    @EnvironmentObject private var sessions: WatchViewState
    @State private var showTalk = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                tiles
                askButton
                if let c = model.snapshot?.counters, !c.czekajace.isEmpty {
                    waitingList(c)
                }
                if let c = model.snapshot?.counters, c.bledy > 0 {
                    // Źródło (np. blokery, ogony) padło na Macu: liczba może być stara albo zerowa.
                    Label("\(c.bledy) \(OrkaCounters.odmiana(c.bledy, "źródło niedostępne", "źródła niedostępne", "źródeł niedostępnych")) — sprawdź panel",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(OrkaTheme.amber)
                }
                if let error = model.error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(OrkaTheme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NavigationLink {
                    LegacyRootView()
                } label: {
                    // Zatwierdzenie Claude czeka: wcześniej arkusz był od razu po otwarciu appki.
                    if sessions.sessions.contains(where: { $0.pendingApproval != nil })
                        || (sessions.sessions.isEmpty && sessions.pendingApproval != nil) {
                        Label("Sesje Claude · zatwierdź", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OrkaTheme.amber)
                    } else {
                        Label("Sesje Claude", systemImage: "terminal")
                            .font(.system(size: 13))
                            .foregroundStyle(OrkaTheme.muted)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 4)
        }
        .background(Color.black)
        .navigationDestination(isPresented: $showTalk) { OrkaTalkView(model: model) }
        // Wyjście z rozmowy (także gestem wstecz w trakcie „Orka myśli…”) porzuca pytanie: bez czytania poza ekranem.
        // Tu, a nie w onDisappear rozmowy: arkusz dyktowania „Zapytaj jeszcze” nie może kasować odpowiedzi.
        .onChange(of: showTalk) { _, shown in if !shown { model.endTalk() } }
        .task {
            #if DEBUG
            if OrkaModel.preview, model.talk != .idle { showTalk = true }
            #endif
            await model.refresh()
        }
    }

    private var header: some View {
        HStack {
            Text("ORKA")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(OrkaTheme.accentText)
            Spacer()
            if model.loading {
                ProgressView().frame(width: 16, height: 16)
            } else {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Text(model.snapshot.map { $0.ageText() == "teraz" ? "teraz" : "\($0.ageText()) temu" } ?? "brak danych")
                        .font(.system(size: 11))
                        .foregroundStyle(model.snapshot?.isStale() == false ? OrkaTheme.muted : OrkaTheme.amber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Odśwież liczniki")
            }
        }
    }

    private var tiles: some View {
        let c = model.snapshot?.counters
        let dim = model.snapshot?.isStale() ?? true
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            OrkaTile(value: c.map { "\($0.czeka)" }, label: "czeka na Ciebie", color: OrkaTheme.amber)
            OrkaTile(value: c.map { "\($0.blokery)" }, label: "blokery",
                     color: (c?.blokery ?? 0) > 0 ? OrkaTheme.red : OrkaTheme.green)
            OrkaTile(value: c.map { "\($0.ogony)" }, label: "szkice", color: OrkaTheme.green)
            OrkaTile(value: c?.limit.map { "\($0.proc)%" }, label: c?.limit.map { "limit k\($0.konto)" } ?? "limit konta",
                     color: (c?.limit?.proc ?? 0) >= 90 ? OrkaTheme.red : OrkaTheme.accentText)
        }
        .opacity(dim ? 0.55 : 1)
    }

    private var askButton: some View {
        TextFieldLink(prompt: Text("Zapytaj Orkę")) {
            Label("Mów do Orki", systemImage: "mic.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color(hex: "03192B"))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 14).fill(OrkaTheme.accent))
        } onSubmit: { text in
            model.ask(text)
            showTalk = true
        }
        .buttonStyle(.plain)
    }

    private func waitingList(_ c: OrkaCounters) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CZEKA NA CIEBIE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(OrkaTheme.muted)
            ForEach(Array(c.czekajace.enumerated()), id: \.offset) { _, s in
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.nazwa).font(.system(size: 13)).lineLimit(2)
                    Text("k\(s.konto)" + (s.issue.map { " · \($0)" } ?? ""))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(OrkaTheme.amber)
                }
                .padding(.vertical, 3)
            }
            if c.czeka > c.czekajace.count {
                Text("i \(c.czeka - c.czekajace.count) więcej w panelu")
                    .font(.system(size: 10))
                    .foregroundStyle(OrkaTheme.muted)
            }
        }
        .padding(.top, 2)
    }
}

struct OrkaTile: View {
    let value: String?
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value ?? "—")
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(color.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 13).fill(color.opacity(0.16)))
        .accessibilityElement(children: .combine)
    }
}

/// Rozmowa: pytanie → „Orka myśli…” → odpowiedź (czytana na głos) → „Zapytaj jeszcze”.
struct OrkaTalkView: View {
    @ObservedObject var model: OrkaModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch model.talk {
                case .idle:
                    Text("Powiedz, o co chcesz zapytać.")
                        .font(.system(size: 13))
                        .foregroundStyle(OrkaTheme.muted)
                case .thinking(let question):
                    questionText(question)
                    HStack(spacing: 6) {
                        ProgressView().frame(width: 18, height: 18)
                        Text("Orka myśli…").font(.system(size: 14)).foregroundStyle(OrkaTheme.accentText)
                    }
                case .answer(let question, let text, let failed):
                    questionText(question)
                    Text(text)
                        .font(.system(size: 15))
                        .foregroundStyle(failed ? OrkaTheme.amber : .white)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.speaking {
                        Button { model.stopSpeaking() } label: {
                            Label("Ucisz", systemImage: "speaker.slash.fill")
                        }
                    } else {
                        Button { model.speak(text) } label: {
                            Label("Powtórz", systemImage: "speaker.wave.2.fill")
                        }
                    }
                }
                TextFieldLink(prompt: Text("Zapytaj Orkę")) {
                    Label("Zapytaj jeszcze", systemImage: "mic.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(hex: "03192B"))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 13).fill(OrkaTheme.accent))
                } onSubmit: { text in
                    model.ask(text)
                }
                .buttonStyle(.plain)
                Button("Zakończ") {
                    model.endTalk()
                    dismiss()
                }
                .foregroundStyle(OrkaTheme.accentText)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Orka")
        .onDisappear { model.stopSpeaking() }
    }

    private func questionText(_ q: String) -> some View {
        Text("„\(q)”")
            .font(.system(size: 12))
            .foregroundStyle(OrkaTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
