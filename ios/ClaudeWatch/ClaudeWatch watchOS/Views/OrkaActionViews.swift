import SwiftUI

/// Potwierdzenie i wynik jednej akcji: „Wyślij „X” do Y?” → Wyślij / Anuluj → Dostarczone / Nie wysłano / nie wiadomo.
/// Każdy tekst wymaga osobnego „Wyślij”; po wyniku niepewnym nie ma ponowienia (jak w panelu).
struct OrkaSendBox: View {
    let target: String
    @Binding var pending: String?
    /// Podniesione do rodzica: w trakcie wysyłki inne przyciski są wyłączone (wynik dotyczy wysłanego tekstu).
    @Binding var sending: Bool
    let send: (String) async -> OrkaActionResult
    @State private var result: OrkaActionResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let text = pending {
                Text("Wyślij „\(text)” do \(target)?")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                if sending {
                    HStack(spacing: 6) { ProgressView().frame(width: 16, height: 16); Text("Wysyłam…").font(.system(size: 12)) }
                } else {
                    HStack {
                        Button("Wyślij") {
                            sending = true
                            Task {
                                let r = await send(text)
                                result = r
                                sending = false
                                pending = nil
                            }
                        }
                        .tint(OrkaTheme.accent)
                        Button("Anuluj", role: .cancel) { pending = nil }
                            .disabled(sending)
                    }
                }
            }
            if let result {
                Text(result.text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(result.delivered ? OrkaTheme.green : OrkaTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: pending) { _, new in if new != nil { result = nil } }
    }
}

/// Czekająca sesja: gotowe odpowiedzi („wdrażaj / zmerguj / ok, leć”) albo podyktowany tekst — przez /pokieruj.
struct OrkaSessionView: View {
    @ObservedObject var model: OrkaModel
    let session: OrkaCounters.Waiting
    @State private var pending: String?
    @State private var sending = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(session.nazwa).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("k\(session.konto)" + (session.issue.map { " · \($0)" } ?? ""))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(OrkaTheme.muted)
                if let target = session.kanal, session.id?.isEmpty == false {
                    ForEach(OrkaActions.quickReplies, id: \.self) { reply in
                        Button(reply) { pending = reply }
                            .tint(reply == "wdrażaj" || reply == "zmerguj" ? OrkaTheme.amber : OrkaTheme.accent)
                            .disabled(sending)
                    }
                    TextFieldLink(prompt: Text("Napisz do sesji")) {
                        Label("Podyktuj…", systemImage: "mic.fill").font(.system(size: 13))
                    } onSubmit: { text in
                        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty { pending = clean }
                    }
                    .disabled(sending)
                    OrkaSendBox(target: "„\(session.nazwa)” (\(target))", pending: $pending, sending: $sending) { text in
                        await model.reply(to: session, text: text)
                    }
                    Text("Albo powiedz Orce — ona przekaże dalej.")
                        .font(.system(size: 10)).foregroundStyle(OrkaTheme.muted)
                } else {
                    Text(session.powod ?? "Do tej sesji nie da się teraz napisać z zegarka.")
                        .font(.system(size: 12)).foregroundStyle(OrkaTheme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Powiedz Orce na ekranie głównym — ona przekaże dalej.")
                        .font(.system(size: 11)).foregroundStyle(OrkaTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Sesja")
        // Akcje odmawiają przy stanie sesji starszym niż 2 min: odśwież od razu.
        .task { await model.refresh(fresh: true) }
    }
}

/// Otwarty bloker: „ok, leć” albo podyktowana odpowiedź — przez /bloker/odpowiedz. Sekretów z zegarka nie podajemy.
struct OrkaBlockerView: View {
    @ObservedObject var model: OrkaModel
    let blocker: OrkaCounters.Blocker
    @State private var pending: String?
    @State private var sending = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bloker #\(blocker.nr) · \(blocker.typ)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(OrkaTheme.red)
                Text(blocker.potrzebuje).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                Text(blocker.sesja + (blocker.issue.map { " · \($0)" } ?? ""))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(OrkaTheme.muted)
                if blocker.mozna {
                    Button("ok, leć") { pending = "ok, leć" }.tint(OrkaTheme.accent).disabled(sending)
                    TextFieldLink(prompt: Text("Odpowiedź na bloker")) {
                        Label("Podyktuj odpowiedź…", systemImage: "mic.fill").font(.system(size: 13))
                    } onSubmit: { text in
                        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty { pending = clean }
                    }
                    .disabled(sending)
                    OrkaSendBox(target: "bloker #\(blocker.nr) (\(blocker.sesja))", pending: $pending, sending: $sending) { text in
                        await model.answer(blocker: blocker.nr, text: text)
                    }
                } else {
                    Text(blocker.typ == "sekret" ? "Sekretów nie podaje się z zegarka — odpowiedz na Macu."
                                                 : "Odpowiedź na ten bloker jest już w drodze.")
                        .font(.system(size: 12)).foregroundStyle(OrkaTheme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Bloker")
        .task { await model.refresh(fresh: true) }
    }
}
