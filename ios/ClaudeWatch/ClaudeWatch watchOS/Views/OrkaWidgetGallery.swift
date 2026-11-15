#if DEBUG
import SwiftUI
import WidgetKit

/// Tylko DEBUG: komplikacje Orki w ramkach zbliżonych do tarczy (zrzuty do podglądu, bez tintowania tarczy).
/// Uruchomienie: `SIMCTL_CHILD_ORKA_GALLERY=1` (+ `ORKA_SEED`) przy `xcrun simctl launch`.
struct OrkaWidgetGallery: View {
    let entry = OrkaEntry(date: Date(), snapshot: OrkaStore.load())

    static var enabled: Bool { ProcessInfo.processInfo.environment["ORKA_GALLERY"] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("KOMPLIKACJE ORKI").font(.system(size: 10, design: .monospaced)).foregroundStyle(.gray)
            OrkaWidgetView(entry: entry, familyOverride: .accessoryRectangular)
                .frame(width: 180, height: 74)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10).stroke(.gray.opacity(0.4)))
            HStack(spacing: 14) {
                OrkaWidgetView(entry: entry, familyOverride: .accessoryCircular)
                    .frame(width: 54, height: 54)
                    .clipShape(Circle())
                Text("okrągła").font(.system(size: 11)).foregroundStyle(.gray)
            }
            OrkaWidgetView(entry: entry, familyOverride: .accessoryInline)
                .font(.system(size: 14))
                .lineLimit(1)
            Text("w linii").font(.system(size: 11)).foregroundStyle(.gray)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
    }
}
#endif
