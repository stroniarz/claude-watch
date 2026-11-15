import SwiftUI
import WidgetKit

// Komplikacja „Orka” na tarczę zegarka (STR-1463) — widoki (też w appce zegarka, podgląd DEBUG). Czyta liczniki z App Group,
// które zapisuje appka zegarka (na pierwszym planie, w zadaniu tła albo po
// paczce z iPhone'a). Rozszerzenie samo nie łączy się z siecią: zegarek nie ma Tailscale.

private enum Palette {
    static let accent = Color(red: 0.12, green: 0.62, blue: 0.86)      // #1E9EDC
    static let amber = Color(red: 0.96, green: 0.79, blue: 0.50)       // #F4C97F
    static let red = Color(red: 1.0, green: 0.48, blue: 0.43)          // #FF7A6E
    static let muted = Color(red: 0.66, green: 0.73, blue: 0.81)       // #A9BBCF
}

struct OrkaEntry: TimelineEntry {
    let date: Date
    let snapshot: OrkaSnapshot?

    var counters: OrkaCounters? { snapshot?.counters }
    var stale: Bool { snapshot?.isStale(at: date) ?? true }

    static let sample = OrkaEntry(date: Date(), snapshot: OrkaSnapshot(counters: OrkaCounters(
        czas: "", wiekS: 120, czeka: 3, pracuje: 7, blokery: 1, ogony: 40, ogonyOtwarte: 92,
        limity: ["1": 68, "2": 97], limit: .init(konto: "2", proc: 97), zdanie: "")))
}

struct OrkaWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: OrkaEntry
    /// Podgląd w appce (DEBUG): rodzina podana wprost, bo poza widgetem środowisko jej nie ma.
    var familyOverride: WidgetFamily? = nil

    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    var body: some View {
        content
            .opacity(entry.stale ? 0.5 : 1)
            .widgetURL(URL(string: "stroniarz://orka"))
            .containerBackground(for: .widget) { Color.black }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryCorner: corner
        case .accessoryInline: inline
        default: rectangular
        }
    }

    private var waiting: String { entry.counters.map { "\($0.czeka)" } ?? "—" }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                Text("Orka").fontWeight(.semibold)
                Spacer(minLength: 2)
                Text(((entry.counters?.bledy ?? 0) > 0 ? "! " : "") + (entry.snapshot?.ageText(at: entry.date) ?? "brak danych"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            .font(.system(size: 13))
            .foregroundStyle(Palette.accent)
            .widgetAccentable()
            if let c = entry.counters {
                Text("\(c.czeka) czeka · \(c.blokery) blok.")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(c.blokery > 0 ? Palette.red : Palette.amber)
                Text(c.draftsText + (c.limitShort.map { " · \($0)" } ?? ""))
                    .font(.system(size: 13))
            } else {
                Text("Otwórz appkę Stroniarz").font(.system(size: 13))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -2) {
                Text(waiting).font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("czeka").font(.system(size: 9))
            }
            if (entry.counters?.blokery ?? 0) > 0 {
                Circle().fill(Palette.red).frame(width: 7, height: 7).offset(x: 14, y: -14)
            }
        }
        .widgetAccentable()
    }

    private var corner: some View {
        Text(waiting)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .widgetCurvesContent()
            .widgetLabel {
                Text(entry.counters.map { "\($0.blokery) blok. · \($0.ogony) szk." } ?? "Orka")
            }
    }

    private var inline: some View {
        if let c = entry.counters {
            Text("Orka \(c.czeka) czeka · \(c.blokery) blok.")   // linia na tarczy jest krótka: bez limitu
        } else {
            Text("Orka: brak danych")
        }
    }
}

