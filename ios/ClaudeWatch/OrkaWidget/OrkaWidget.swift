import SwiftUI
import WidgetKit

struct OrkaProvider: TimelineProvider {
    func placeholder(in context: Context) -> OrkaEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (OrkaEntry) -> Void) {
        completion(context.isPreview && OrkaStore.load() == nil ? .sample : OrkaEntry(date: Date(), snapshot: OrkaStore.load()))
    }

    /// Dane przychodzą z appki (reloadTimelines). Co 15 min tylko przeliczamy wiek i wyszarzenie.
    func getTimeline(in context: Context, completion: @escaping (Timeline<OrkaEntry>) -> Void) {
        let snapshot = OrkaStore.load()
        let now = Date()
        let entries = (0..<8).map { OrkaEntry(date: now.addingTimeInterval(Double($0) * 900), snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(2 * 3600))))
    }
}

struct OrkaCountersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: OrkaStore.widgetKind, provider: OrkaProvider()) { entry in
            OrkaWidgetView(entry: entry)
        }
        .configurationDisplayName("Orka")
        .description("Ile czeka na Ciebie, blokery, szkice i limit konta. Dotknij, by otworzyć Orkę.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

@main
struct OrkaWidgetBundle: WidgetBundle {
    var body: some Widget { OrkaCountersWidget() }
}

#Preview(as: .accessoryRectangular) {
    OrkaCountersWidget()
} timeline: {
    OrkaEntry.sample
    OrkaEntry(date: Date(), snapshot: nil)
}
