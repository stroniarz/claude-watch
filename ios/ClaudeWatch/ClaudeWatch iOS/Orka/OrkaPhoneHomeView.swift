import SwiftUI

struct OrkaPhoneHomeView: View {
    private enum Route: Hashable {
        case session(OrkaCounters.Waiting)
        case blocker(OrkaCounters.Blocker)
        case chat
    }
    @ObservedObject var model: OrkaPhoneModel
    let active: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(value: Route.chat) {
                        Label("Mów do Orki", systemImage: "bubble.left.and.text.bubble.right.fill")
                            .font(.headline).padding(.vertical, 8)
                    }
                } footer: {
                    Text("Napisz lub użyj mikrofonu na klawiaturze. Odpowiedzi Orki znajdziesz w rozmowie.")
                }

                if let snapshot = model.snapshot {
                    Section {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                            counter("Czeka", value: "\(snapshot.counters.czeka)", symbol: "hourglass")
                            counter("Blokery", value: "\(snapshot.counters.blokery)", symbol: "exclamationmark.octagon")
                            counter("Szkice", value: "\(snapshot.counters.ogony)", symbol: "doc.text")
                            counter("Limit", value: snapshot.counters.limitShort ?? "Brak danych", symbol: "gauge.with.dots.needle.67percent")
                        }
                        .padding(.vertical, 8)
                        Text("Aktualność stanu Maca: \(snapshot.ageText())")
                            .font(.caption).foregroundStyle(.secondary)
                        if !snapshot.counters.zdanie.isEmpty { Text(snapshot.counters.zdanie) }
                        if snapshot.isStale() {
                            Label("Dane są nieaktualne. Odśwież przed podjęciem decyzji.", systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(.orange)
                        }
                    }
                    Section("Czeka na Ciebie") {
                        if snapshot.counters.czekajace.isEmpty { Text("Żadna sesja teraz nie czeka.").foregroundStyle(.secondary) }
                        ForEach(snapshot.counters.czekajace, id: \.self) { session in
                            // Pełna wartość zostaje w ścieżce nawigacji, także po odświeżeniu listy.
                            NavigationLink(value: Route.session(session)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.nazwa).font(.headline)
                                    Text([session.issue, "konto \(session.konto)"].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if snapshot.counters.czeka > snapshot.counters.czekajace.count {
                            Text("i \(snapshot.counters.czeka - snapshot.counters.czekajace.count) więcej — zobacz zakładkę Panel")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Blokery") {
                        if snapshot.counters.blokeryLista.isEmpty { Text("Brak blokerów.").foregroundStyle(.secondary) }
                        ForEach(snapshot.counters.blokeryLista) { blocker in
                            NavigationLink(value: Route.blocker(blocker)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("#\(blocker.nr) · \(blocker.sesja)").font(.headline)
                                    Text(blocker.potrzebuje).lineLimit(2).foregroundStyle(.secondary)
                                    if blocker.typ == "sekret" { Text("Odpowiedz na Macu").foregroundStyle(.orange) }
                                }
                            }
                        }
                    }
                } else if model.loading {
                    ProgressView("Pobieram stan Orki…")
                } else {
                    Text("Nie mam jeszcze danych z Maca. Przeciągnij ekran w dół, aby odświeżyć.")
                }
                if let error = model.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Odśwież") { Task { await model.refresh(fresh: true) } }
                    }
                }
            }
            .navigationTitle("Orka")
            .refreshable { await model.refresh(fresh: true) }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .session(let session): OrkaPhoneSessionView(model: model, session: session)
                case .blocker(let blocker): OrkaPhoneBlockerView(model: model, blocker: blocker)
                case .chat: OrkaPhoneChatView(model: model)
                }
            }
        }
        .task(id: active) {
            if active { await model.runVisible() } else { model.suspend() }
        }
        .onDisappear { model.suspend() }
    }

    private func counter(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OrkaPhoneSessionView: View {
    @ObservedObject var model: OrkaPhoneModel
    let session: OrkaCounters.Waiting
    @State private var checked = false

    /// Po świeżym odczycie: czy ta sesja (konto + id) nadal czeka. Serwer sprawdza tylko istnienie i cel,
    /// nie stan — „zmerguj” nie może trafić do sesji, która zajęła się czymś innym (review r1).
    private var stillWaiting: Bool {
        guard let list = model.snapshot?.counters.czekajace else { return false }
        return list.contains { $0.konto == session.konto && $0.id == session.id }
    }

    var body: some View {
        Form {
            Section("Sesja") {
                Text(session.nazwa).font(.headline)
                if let issue = session.issue { Text(issue) }
                Text("Konto \(session.konto)").foregroundStyle(.secondary)
            }
            if !checked {
                Section { ProgressView("Sprawdzam, czy sesja nadal czeka…") }
            } else if !stillWaiting {
                Section {
                    Label("Ta sesja już nie czeka na Ciebie — szybkie odpowiedzi są wyłączone.", systemImage: "checkmark.circle")
                    Text("Jeśli chcesz coś jej przekazać, napisz do Orki.").foregroundStyle(.secondary)
                }
            } else if session.id?.isEmpty == false, session.kanal?.isEmpty == false {
                OrkaPhoneReplyForm(model: model, target: .session(session), quickReplies: OrkaActions.quickReplies)
            } else {
                Section {
                    Text(session.powod ?? "Do tej sesji nie da się teraz napisać z telefonu.")
                    Text("Napisz do Orki — ona przekaże dalej.")
                }
            }
        }
        .navigationTitle("Odpowiedź sesji")
        .task {
            await model.refresh(fresh: true)
            checked = true
        }
    }
}

struct OrkaPhoneBlockerView: View {
    @ObservedObject var model: OrkaPhoneModel
    let blocker: OrkaCounters.Blocker

    var body: some View {
        Form {
            Section("Bloker #\(blocker.nr)") {
                Text(blocker.sesja).font(.headline)
                if let issue = blocker.issue { Text(issue) }
                Text(blocker.potrzebuje)
            }
            if blocker.typ == "sekret" {
                Section { Label("Odpowiedz na Macu — sekretów nie podawaj w telefonie.", systemImage: "lock") }
            } else if blocker.mozna {
                OrkaPhoneReplyForm(model: model, target: .blocker(blocker), quickReplies: ["ok, leć"])
            } else {
                Section { Text("Odpowiedź na ten bloker jest już w drodze. Sprawdź stan na Macu.") }
            }
        }
        .navigationTitle("Bloker")
        .task { await model.refresh(fresh: true) }
    }
}

/// Potwierdzenie zawiera dokładny tekst i zamrożony cel. Nie ma automatycznych powtórek POST.
private struct OrkaPhoneReplyForm: View {
    @ObservedObject var model: OrkaPhoneModel
    let target: OrkaPhoneAction.Target
    let quickReplies: [String]
    @State private var text = ""
    @State private var pending: OrkaPhoneAction?

    private var sending: Bool { model.inFlight.contains(OrkaPhoneAction.key(target)) }
    private var recent: (text: String, result: OrkaActionResult, at: Date)? { model.recentResult(for: target) }
    /// Po „dostarczone” albo „nie wiadomo” nie wysyłamy ponownie z tego ekranu; „nie wysłano” jest pewne — można poprawić.
    private var locked: Bool {
        guard let r = recent?.result else { return false }
        if case .notSent = r { return false }
        return true
    }

    var body: some View {
        Section("Odpowiedz") {
            if let recent {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wysłano „\(recent.text)” o \(recent.at.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(recent.result.text).foregroundStyle(recent.result.delivered ? Color.green : Color.orange)
                }
            }
            ForEach(quickReplies, id: \.self) { reply in
                Button(reply) { pending = OrkaPhoneAction(target: target, text: reply) }
            }
            TextField("Napisz lub podyktuj odpowiedź", text: $text, axis: .vertical).lineLimit(3...8)
            Button("Dalej") { pending = OrkaPhoneAction(target: target, text: text) }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if sending { ProgressView("Wysyłam…") }
        }
        .disabled(sending || locked)
        .sheet(item: $pending) { action in
            NavigationStack {
                Form {
                    Section("Do kogo") { Text(action.title) }
                    Section("Wiadomość") { Text(action.text) }
                    Section {
                        Button("Wyślij") {
                            // Blokada ustawia się synchronicznie, przed uruchomieniem żądania.
                            guard !sending else { return }
                            model.markInFlight(action)
                            pending = nil
                            Task { _ = await model.perform(action) }
                        }.buttonStyle(.borderedProminent).disabled(sending)
                    }
                }
                .navigationTitle("Potwierdź wysłanie")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { pending = nil } } }
            }
        }
    }
}

struct OrkaPhoneChatView: View {
    @ObservedObject var model: OrkaPhoneModel
    @State private var text = ""

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Text("Rozmawiasz z Orką. Możesz dyktować przyciskiem mikrofonu na klawiaturze.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.conversation.lines) { line in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(line.who == .me ? "Ty" : line.who == .orka ? "Orka" : "Status")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                        Text(line.text).textSelection(.enabled)
                    }.id(line.id)
                }
                if let status = model.chatStatus { Text(status).font(.callout).foregroundStyle(.secondary) }
                if let note = model.voiceNote { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .onChange(of: model.conversation.lines.last?.id) { _, _ in
                if let last = model.conversation.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onAppear {
                if let last = model.conversation.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom) {
                TextField("Napisz do Orki…", text: $text, axis: .vertical)
                    .lineLimit(1...6).textFieldStyle(.roundedBorder)
                Button("Wyślij") {
                    let message = text
                    text = ""
                    Task { await model.tellOrka(message) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding().background(.bar)
        }
        .navigationTitle("Mów do Orki")
        .toolbar { Button("Wycisz") { model.stopSpeaking() } }
        .onAppear { model.setChatVisible(true) }
        .onDisappear { model.setChatVisible(false) }
    }
}
