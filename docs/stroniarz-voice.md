# Stroniarz Voice: rozmowa ze Stroniarzem bez rąk (STR-1281)

Appka claude-watch (nazwa na ekranie: **Stroniarz**) ma moduł `Shared/StroniarzVoice`, wspólny dla iPhone'a i zegarka. Moduł rozmawia z usługą `voice_inbox.handsfree` na Macu (STR-1279):
- iPhone łączy się po HTTPS przez Tailscale: `https://michas-macbook-pro.tail5f86bd.ts.net:8444`;
- zegarek pyta przez iPhone'a (WCSession).

```
Siri / Skrót ──▶ App Intent (iPhone) ──HTTPS + Bearer z Keychain──▶ Mac :8444 → :6102
Siri (zegarek) ──▶ App Intent (watch) ──WCSession──▶ iPhone ──▶ jw.
```

## Co jest w appce

| Akcja (Skróty / Siri) | Co robi |
|---|---|
| **Rozmawiaj ze Stroniarzem** (`ConverseIntent`) | Pętla dialogów Siri: „Słucham.” → pytanie → odpowiedź + „Coś jeszcze?” → … Kończą ją „koniec”, „stop”, „dzięki”, „nie, dzięki”, „to wszystko”. „Raport” czyta `/brief`. Najwyżej 8 rund. |
| **Raport Stroniarz** (`BriefIntent`) | Czyta `/brief`. |
| **Zapytaj Stroniarza** (`AskStroniarzIntent`) | Klocek do własnego skrótu: tekst → odpowiedź (tekst, bez mówienia). Gdy rozmowa się kończy („koniec”, „dzięki”, brak połączenia, zły token), odpowiedź kończy się na `Do usłyszenia.`. Pytania w odstępie do 3 minut są jedną rozmową (`conversation_id`), więc działa „a Yard?”. |
| **Sprawdź połączenie ze Stroniarzem** | `/ping`. |

Błędy przychodzą jako zdania do powiedzenia:

| Sytuacja | Co słychać |
|---|---|
| sieć / Tailscale / Mac śpi | „Nie mam połączenia z Makiem, sprawdź Tailscale.” |
| 12 s bez odpowiedzi | „Mac nie odpowiedział na czas. Zapytaj jeszcze raz albo powiedz: i co?” |
| zły token | „Brak dostępu. Sprawdź token w ustawieniach aplikacji Stroniarz.” |
| limit | zdanie z serwera („Za dużo pytań naraz…”, „…Spróbuj za kwadrans.”) |
| zegarek bez iPhone'a | „Nie widzę iPhone'a. Zbliż zegarek do telefonu…” |

Ważne: **Siri nie obsługuje polskiego.** Polski jest tylko w Dyktowaniu. `ConverseIntent` dyktuje i mówi w języku Siri. Jeśli Siri jest po angielsku, polskie pytania nie zostaną poprawnie rozpoznane. Wtedy użyj wariantu B: osobistego skrótu z polskim „Dyktuj tekst” i „Powiedz tekst” (niżej). Wieczorny test rozstrzyga, który wariant zostaje.

## Instalacja (z Michałem, wieczorem)

Mac:
1. `cd ios/ClaudeWatch && xcodegen generate`. Projekt jest w repo, ale po zmianach w `project.yml` trzeba go wygenerować ponownie.
2. iPhone podłącz kablem. **Nie wyłączaj Tailscale na Macu.** Gotcha: devicectl do zegarka pada przy włączonym Tailscale. Wtedy instaluj zegarek z Xcode (Run na schemacie `ClaudeWatchWatch`) albo przez iPhone'a: appka Watch → Stroniarz → Zainstaluj.
3. Xcode: schemat `ClaudeWatch`, urządzenie iPhone, Run. Zespół 6FS27R7XXZ, podpis automatyczny.
4. Token do schowka: `bash tools/install_handsfree.sh --copy` w `stroniarz.pl/tools/voice-inbox`. Jeśli usługa już działa, wystarczy `pbcopy < ~/.config/voice-handsfree/token`. Nie wklejaj tokenu do czatu.

iPhone:
1. Appka Stroniarz → ⚙︎ → **Stroniarz Voice**:
   - adres zostaw domyślny;
   - **Wklej token ze schowka** (po zapisie appka czyści schowek);
   - **Test połączenia** powinien powiedzieć „Połączenie jest…”.
2. Ustawienia → Siri:
   - „Zezwalaj na Siri, gdy zablokowane”;
   - „Odpowiedzi głosowe”: zawsze.
3. Tailscale → VPN On Demand: Always.
4. Pierwsze uruchomienie każdej akcji zrób na odblokowanym telefonie i zaakceptuj zgody.

### Wariant A: Siri bez skrótu

Powiedz „Hej Siri, Talk to Stroniarz” albo „Rozmawiaj z Stroniarz”. Frazy z appki muszą zawierać jej nazwę. Ładniejszą nazwę, np. „Rozmawiaj ze Stroniarzem”, daje osobisty skrót z jedną akcją: Skróty → + → akcja „Rozmawiaj ze Stroniarzem” → nazwij skrót „Rozmawiaj ze Stroniarzem”.

### Wariant B: osobisty skrót z polskim dyktowaniem (rekomendowany, gdy Siri nie mówi po polsku)

Skróty → nowy skrót „Rozmawiaj ze Stroniarzem”:
1. **Powtórz** 8 razy, a w pętli:
   1. **Powiedz tekst** `Słucham.` (język polski, głos np. Zosia).
   2. **Dyktuj tekst**: język polski, przestań słuchać „Po pauzie”.
   3. **Jeżeli** *Dyktowany tekst* zawiera `koniec`: **Powiedz tekst** `Do usłyszenia.` → **Zatrzymaj ten skrót**.
   4. **Powiedz tekst** `Myślę.`
   5. **Zapytaj Stroniarza** (akcja appki Stroniarz), Pytanie = *Dyktowany tekst*.
   6. **Powiedz tekst**: *Odpowiedź Stroniarza* (język polski).
   7. **Jeżeli** *Odpowiedź Stroniarza* zawiera `Do usłyszenia`: **Zatrzymaj ten skrót**. Akcja tak kończy rozmowę po „dzięki”, „nie, dzięki” albo przy braku połączenia.
2. Szczegóły skrótu: „Zezwalaj na uruchamianie, gdy zablokowane”.

Token nie jest potrzebny w skrócie, bo appka bierze go z Keychain.

### Zegarek

Intenty są też w appce na zegarku. Pytanie idzie przez iPhone'a (WCSession), więc telefon musi być w zasięgu Bluetooth/Wi-Fi. Gdy Mac będzie publiczny (Tailscale Funnel, decyzja otwarta), w ustawieniach iPhone'a użyj **Wyślij ustawienia na zegarek**. Wtedy zegarek bez telefonu połączy się sam.

## Test na urządzeniu: co sprawdzić i wpisać do STR-1281

1. Zablokowany iPhone, AirPods: „Hej Siri, Raport Stroniarz” → czyta raport?
2. Wariant A: czy działają kolejne rundy `requestValue` („Coś jeszcze?” → pytanie)? Ile rund? Czy działa zakończenie słowem „koniec”? W jakim języku Siri rozpoznaje mowę?
3. „Myślę” z przełącznika eksperymentalnego: czy słychać je na AirPods, gdy Mac liczy dłużej niż 1,5 s? Czy nie zagłusza odpowiedzi Siri?
4. Wariant B: pełna pętla ze skrótu, w tym dopytanie „a Yard?” po „co z Gastronetem?”.
5. Tailscale na iPhonie wyłączony → „Nie mam połączenia z Makiem, sprawdź Tailscale.”
6. Zegarek: „Hej Siri, Raport Stroniarz” i rozmowa przez iPhone'a.

## Kod

- `Shared/StroniarzVoice/HandsfreeClient.swift`: URLSession, timeout 12 s, mapowanie błędów na zdania.
- `HandsfreeSettings.swift`: adres w UserDefaults, token w Keychain (`AfterFirstUnlockThisDeviceOnly`, czytelny przy zablokowanym telefonie).
- `ConversationEngine.swift`: pętla rozmowy niezależna od Siri (testowalna), słowa końca, `ConversationStore`.
- `SpeechThinkingCue.swift`: eksperymentalne „Myślę” przez AVSpeechSynthesizer (iOS, tryb tła `audio`).
- `VoiceRelay.swift`: relay zegarek → iPhone i obsługa po stronie iPhone'a.
- `Intents/StroniarzIntents.swift`: intenty i `AppShortcutsProvider`.
- `ClaudeWatch iOS/Views/VoiceSettingsView.swift`: ekran ustawień.
- Testy: `StroniarzVoiceTests/` (mock `URLProtocol`, pętla rozmowy). Uruchomienie: `xcodebuild test -scheme ClaudeWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.

Serwer (`conversation_id`, ostatnie 3 pary w kontekście): stroniarz-hq, gałąź `str-1281-conversation` (z PR #93).

## Orka na zegarku (STR-1463)

Appka zegarka startuje na ekranie **Orka**: liczniki panelu i „Mów do Orki”. Dotychczasowe sesje Claude/Codex (bridge) są pod przyciskiem „Sesje Claude” na dole ekranu.

```
komplikacja ← App Group ← appka zegarka ⇄ WCSession ⇄ appka iPhone ⇄ HTTPS (Tailscale :8444)
                                                       GET  /panel/api/zegarek   liczniki (~0,5 KB)
                                                       POST /panel/api/jarvis    Orka
```

| Co | Jak działa |
|---|---|
| Kafelki | czeka na Ciebie · blokery (czerwone > 0) · szkice do wysłania · limit konta (najwyższy z k1/k2, czerwony ≥ 90%) + wiek danych; do 3 czekających sesji |
| „Mów do Orki” | systemowe dyktowanie (`TextFieldLink`) → op `orka` przez iPhone'a → `/panel/api/jarvis` → odpowiedź na ekranie i głosem pl-PL (`AVSpeechSynthesizer`). T3 („zleć …”) → „Zleceń nie uruchamiam z zegarka. Powiedz to samo w panelu Orki…” (panel nie przechowuje propozycji, więc nie ma czego potwierdzać) — z zegarka nic się nie uruchamia. Limit czasu 28 s (+4 s relay). |
| Komplikacja `OrkaWidget` | rodziny: prostokątna („Orka · 9 czeka · 3 blok. · 40 szkiców · k2 98%”), okrągła (liczba „czeka”, czerwona kropka przy blokerach), narożna, w linii. Dane > 2 h są wyszarzone. Dotknięcie → `stroniarz://orka`. |
| Odświeżanie | na pierwszym planie przy otwarciu/powrocie; w tle `WKApplication.scheduleBackgroundRefresh` ~co 15 min (budżet watchOS). W tle krótka (6 s) próba op `zegarek` przez iPhone'a (`sendMessage` budzi appkę iOS). Gdy się nie da: `transferUserInfo(orkaRefresh)` (najwyżej co 30 min, poprzednia niedoręczona prośba anulowana) — **iOS nie gwarantuje obudzenia appki dla transferUserInfo**, więc ta ścieżka działa, gdy appka Stroniarz na iPhonie żyje w tle. iPhone łączy prośby (co ≥ 60 s), wysyła snapshot z datą danych przez `transferCurrentComplicationUserInfo` (albo zwykłe `transferUserInfo`, gdy budżet komplikacji się skończył); zegarek odbiera go w `.backgroundTask(.watchConnectivity)`, nie cofa się do starszych danych. |

Kod: `Shared/StroniarzVoice/OrkaCounters.swift` (model + App Group `group.pl.stroniarz.claudewatch`, wspólny z widgetem), `OrkaClient.swift` (HTTPS), `OrkaSync.swift` (tło), `VoiceRelay.swift` (op `zegarek`, `orka`), `ClaudeWatch watchOS/Services/OrkaModel.swift`, `Views/OrkaHomeView.swift`, `OrkaWidget/`. Testy: `StroniarzVoiceTests/OrkaTests.swift`.

Instalacja: jak wyżej (Xcode, zespół 6FS27R7XXZ, podpis automatyczny). Nowe: App Group w obu targetach zegarka — przy pierwszym buildzie na urządzenie Xcode musi ją zarejestrować (`-allowProvisioningUpdates` albo Run z Xcode z zalogowanym kontem). Komplikację dodaje się na tarczy: przytrzymaj tarczę → Edytuj → Komplikacje → Stroniarz → Orka.

Podgląd w symulatorze (tylko Debug): `SIMCTL_CHILD_ORKA_SEED=<plik JSON z /panel/api/zegarek>` i opcjonalnie `SIMCTL_CHILD_ORKA_TALK="pytanie|odpowiedź"` przy `xcrun simctl launch`.
