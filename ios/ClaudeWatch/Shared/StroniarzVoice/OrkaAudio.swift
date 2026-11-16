import Foundation
import WatchConnectivity

/// Głos voice-inbox na zegarku (STR-1463): iPhone syntezuje przez `/panel/api/mow` i przesyła plik
/// (`WCSession.transferFile` — wiadomości WCSession mają limit ~64 KB, a mp3 odpowiedzi ma 50–200 KB).
enum OrkaAudio {
    static let idKey = "orkaAudio"
    static let mimeKey = "mime"

    #if os(iOS)
    /// iPhone: synteza głosem voice-inbox i wysyłka pliku na zegarek. `true` = plik w kolejce WCSession.
    static func sendSpeech(_ text: String, id: String, client: HandsfreeClient = .fromSettings()) async -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !id.isEmpty, WCSession.isSupported() else { return false }
        let session = WCSession.default
        guard session.activationState == .activated, session.isWatchAppInstalled,
              let audio = await client.speech(clean) else { return false }
        let ext = audio.mime.contains("wav") ? "wav" : "mp3"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orka-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        guard (try? audio.data.write(to: url)) != nil else { return false }
        session.transferFile(url, metadata: [idKey: id, mimeKey: audio.mime])
        return true
    }

    /// iPhone: po wysłaniu (albo porażce) plik w tmp nie jest już potrzebny.
    static func transferFinished(_ url: URL) {
        guard url.path.contains("/orka-audio/") else { return }
        try? FileManager.default.removeItem(at: url)
    }
    #endif

    #if os(watchOS)
    static let didArrive = Notification.Name("OrkaAudio.didArrive")

    /// Zegarek: plik z iPhone'a znika po powrocie z delegata — kopiujemy go od razu.
    static func receive(_ file: WCSessionFile) -> Bool {
        guard let id = file.metadata?[idKey] as? String, !id.isEmpty else { return false }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orka-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Sprzątamy tylko pliki starsze niż 15 min — bieżąca odpowiedź („Powtórz”) zostaje.
        let cutoff = Date().addingTimeInterval(-900)
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: old) }
        }
        let target = dir.appendingPathComponent(id + "." + (file.fileURL.pathExtension.isEmpty ? "mp3" : file.fileURL.pathExtension))
        guard (try? FileManager.default.copyItem(at: file.fileURL, to: target)) != nil else { return true }
        NotificationCenter.default.post(name: didArrive, object: nil, userInfo: ["id": id, "url": target])
        return true
    }
    #endif
}
