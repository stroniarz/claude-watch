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
    static let ink = Color(hex: "03192B")
}

/// Ekran główny appki (STR-1463): liczniki, „Mów do Orki” (wprost do Orki-orkiestratorki), akcje.
struct OrkaHomeView: View {
    @ObservedObject var model: OrkaModel
    @EnvironmentObject private var sessions: WatchViewState
    @State private var showTalk = false
    @State private var showChat = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                tiles
                talkToOrka
                if !model.chat.isEmpty {
                    NavigationLink { OrkaChatView(model: model) } label: {
                        Label("Rozmowa z Orką", systemImage: "bubble.left.and.bubble.right")
                            .font(.system(size: 13)).foregroundStyle(OrkaTheme.accentText)
                    }
                }
                if let c = model.snapshot?.counters, !c.czekajace.isEmpty { waitingList(c) }
                if let c = model.snapshot?.counters, !c.blokeryLista.isEmpty { blockerList(c) }
                quickQuestion
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
        .navigationDestination(isPresented: $showChat) { OrkaChatView(model: model) }
        // Wyjście z szybkiego pytania porzuca je: bez czytania poza ekranem. Tu, a nie w onDisappear widoku:
        // arkusz dyktowania „Zapytaj jeszcze” nie może kasować odpowiedzi.
        .onChange(of: showTalk) { _, shown in if !shown { model.endTalk() } }
        .task {
            #if DEBUG
            if OrkaModel.preview, model.talk != .idle { showTalk = true }
            if OrkaModel.preview, !model.chat.isEmpty { showChat = true }
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

    /// Główny przycisk: wiadomość wprost do sesji orkiestratora (Michał 15.11: „trzeba wprost do Orki”).
    private var talkToOrka: some View {
        TextFieldLink(prompt: Text("Powiedz Orce")) {
            Label("Mów do Orki", systemImage: "mic.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(OrkaTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 14).fill(OrkaTheme.accent))
        } onSubmit: { text in
            model.tellOrka(text)
            showChat = true
        }
        .buttonStyle(.plain)
    }

    /// Szybkie pytanie do asystenta panelu (odpowiada od razu z tablic; do decyzji — Orka).
    private var quickQuestion: some View {
        TextFieldLink(prompt: Text("Szybkie pytanie")) {
            Label("Szybkie pytanie (panel)", systemImage: "bolt.fill")
                .font(.system(size: 12))
                .foregroundStyle(OrkaTheme.muted)
        } onSubmit: { text in
            model.ask(text)
            showTalk = true
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private func waitingList(_ c: OrkaCounters) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("CZEKA NA CIEBIE")
            ForEach(Array(c.czekajace.enumerated()), id: \.offset) { _, s in
                NavigationLink { OrkaSessionView(model: model, session: s) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.nazwa).font(.system(size: 13)).lineLimit(2)
                        Text("k\(s.konto)" + (s.issue.map { " · \($0)" } ?? "") + (s.kanal == nil ? "" : " · odpowiedz"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(s.kanal == nil ? OrkaTheme.muted : OrkaTheme.amber)
                    }
                    .padding(.vertical, 2)
                }
            }
            if c.czeka > c.czekajace.count {
                Text("i \(c.czeka - c.czekajace.count) więcej w panelu")
                    .font(.system(size: 10))
                    .foregroundStyle(OrkaTheme.muted)
            }
        }
        .padding(.top, 2)
    }

    private func blockerList(_ c: OrkaCounters) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("BLOKERY")
            ForEach(c.blokeryLista) { b in
                NavigationLink { OrkaBlockerView(model: model, blocker: b) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("#\(b.nr) \(b.potrzebuje)").font(.system(size: 12)).lineLimit(2)
                        Text(b.typ + (b.issue.map { " · \($0)" } ?? ""))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(b.mozna ? OrkaTheme.red : OrkaTheme.muted)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.top, 2)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(OrkaTheme.muted)
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

/// Rozmowa z Orką-orkiestratorką: Ty → Orka (sesja Claude) → odpowiedź ze skrzynki zegarka, głosem voice-inbox.
struct OrkaChatView: View {
    @ObservedObject var model: OrkaModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.chat) { line in
                    switch line.who {
                    case .me:
                        Text(line.text).font(.system(size: 13)).foregroundStyle(OrkaTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing)
                    case .orka:
                        Text(line.text).font(.system(size: 15)).foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    case .info:
                        Text(line.text).font(.system(size: 11)).foregroundStyle(OrkaTheme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                status
                if let note = model.voiceNote {
                    Text(note).font(.system(size: 10)).foregroundStyle(OrkaTheme.muted)
                }
                if let last = model.chat.last(where: { $0.who == .orka }) {
                    if model.speaking {
                        Button { model.stopSpeaking() } label: { Label("Ucisz", systemImage: "speaker.slash.fill") }
                    } else {
                        Button { model.replay(last.text) } label: { Label("Powtórz", systemImage: "speaker.wave.2.fill") }
                    }
                }
                TextFieldLink(prompt: Text("Powiedz Orce")) {
                    Label("Powiedz jeszcze", systemImage: "mic.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(OrkaTheme.ink)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 13).fill(OrkaTheme.accent))
                } onSubmit: { text in
                    model.tellOrka(text)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Orka")
        .onAppear { model.catchUpReplies() }
    }

    @ViewBuilder private var status: some View {
        switch model.chatStatus {
        case .idle: EmptyView()
        case .sending:
            HStack(spacing: 6) { ProgressView().frame(width: 16, height: 16); Text("Wysyłam do Orki…").font(.system(size: 12)) }
                .foregroundStyle(OrkaTheme.accentText)
        case .waiting:
            HStack(spacing: 6) { ProgressView().frame(width: 16, height: 16); Text("Orka dostała, czekam na odpowiedź…").font(.system(size: 12)) }
                .foregroundStyle(OrkaTheme.accentText)
        case .failed(let why):
            Text(why).font(.system(size: 12)).foregroundStyle(OrkaTheme.amber).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Szybkie pytanie do asystenta panelu: pytanie → odpowiedź (głos voice-inbox) → „Zapytaj jeszcze”.
struct OrkaTalkView: View {
    @ObservedObject var model: OrkaModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch model.talk {
                case .idle:
                    Text("Zadaj szybkie pytanie o stan.")
                        .font(.system(size: 13))
                        .foregroundStyle(OrkaTheme.muted)
                case .thinking(let question):
                    questionText(question)
                    HStack(spacing: 6) {
                        ProgressView().frame(width: 18, height: 18)
                        Text("Sprawdzam…").font(.system(size: 14)).foregroundStyle(OrkaTheme.accentText)
                    }
                case .answer(let question, let text, let failed):
                    questionText(question)
                    Text(text)
                        .font(.system(size: 15))
                        .foregroundStyle(failed ? OrkaTheme.amber : .white)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = model.voiceNote {
                        Text(note).font(.system(size: 10)).foregroundStyle(OrkaTheme.muted)
                    }
                    if model.speaking {
                        Button { model.stopSpeaking() } label: { Label("Ucisz", systemImage: "speaker.slash.fill") }
                    } else {
                        Button { model.replay(text) } label: { Label("Powtórz", systemImage: "speaker.wave.2.fill") }
                    }
                }
                TextFieldLink(prompt: Text("Szybkie pytanie")) {
                    Label("Zapytaj jeszcze", systemImage: "mic.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(OrkaTheme.ink)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 13).fill(OrkaTheme.accent))
                } onSubmit: { text in
                    model.ask(text)
                }
                .buttonStyle(.plain)
                Button("Zakończ") { dismiss() }
                    .foregroundStyle(OrkaTheme.accentText)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Panel")
        .onDisappear { model.stopSpeaking() }
    }

    private func questionText(_ q: String) -> some View {
        Text("„\(q)”")
            .font(.system(size: 12))
            .foregroundStyle(OrkaTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
