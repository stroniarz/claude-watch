import Foundation

/// Everything the voice flow says out loud, plus the words that steer it.
/// Kept in one place so the Siri dialogs, the Shortcuts action and the tests agree.
enum VoicePhrases {
    static let listening = "Słucham."
    static let thinking = "Myślę."
    static let anythingElse = "Coś jeszcze?"
    static let goodbye = "Do usłyszenia."
    static let didNotHear = "Nie usłyszałem. Powtórz, proszę."
    static let turnLimit = "Kończę rozmowę, żeby nie trwała w nieskończoność. Do usłyszenia."

    static let noConnection = "Nie mam połączenia z Makiem, sprawdź Tailscale."
    static let timeout = "Mac nie odpowiedział na czas. Zapytaj jeszcze raz albo powiedz: i co?"
    static let unauthorized = "Brak dostępu. Sprawdź token w ustawieniach aplikacji Stroniarz."
    static let tooMany = "Za dużo pytań naraz. Odczekaj minutę."
    static let serverError = "Coś poszło nie tak po stronie Maca. Spróbuj za chwilę."
    static let notConfigured = "Nie mam adresu albo tokenu. Otwórz aplikację Stroniarz i uzupełnij ustawienia."
    static let noPhone = "Nie widzę iPhone'a. Zbliż zegarek do telefonu i spróbuj jeszcze raz."

    /// "Koniec", "stop" end the conversation when the reply is just a command
    /// ("dobra, koniec"), not a question about it ("kiedy koniec umowy?").
    private static let strongEnd: Set<String> = ["koniec", "stop", "zakończ", "zakoncz", "wystarczy"]
    /// A reply made only of these words ends it too ("nie, dzięki", "to wszystko"),
    /// but "a nie Yard?" does not.
    private static let softEnd: Set<String> = [
        "nie", "nic", "dzięki", "dziękuję", "dzieki", "dziekuje", "pa", "to", "już", "juz",
        "wszystko", "tyle", "na", "razie", "no", "ok", "okej", "dobra",
    ]
    private static let softMarkers: Set<String> = [
        "nie", "nic", "dzięki", "dziękuję", "dzieki", "dziekuje", "pa", "wszystko", "tyle", "razie",
    ]

    /// Lowercased words without punctuation.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    static func isEnd(_ text: String) -> Bool {
        let w = words(text)
        guard !w.isEmpty, w.count <= 4 else { return false }
        guard w.allSatisfy({ strongEnd.contains($0) || softEnd.contains($0) }) else { return false }
        return w.contains(where: strongEnd.contains) || w.contains(where: softMarkers.contains)
    }

    /// "Raport", "raport Stroniarz", "daj raport" → read /brief instead of asking.
    static func isBrief(_ text: String) -> Bool {
        let w = words(text)
        guard !w.isEmpty, w.count <= 3 else { return false }
        return w.contains("raport") || w.contains("brief")
    }
}
