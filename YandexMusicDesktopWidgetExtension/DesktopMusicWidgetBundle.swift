import WidgetKit
import SwiftUI

@main
struct DesktopMusicWidgetBundle: WidgetBundle {
    var body: some Widget {
        DesktopMusicWidget()
    }
}

struct DesktopMusicWidget: Widget {
    let kind: String = "DesktopMusicWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: ConfigurationAppIntent.self,
            provider: WidgetProvider()
        ) { entry in
            DesktopMusicWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Яндекс Музыка")
        .description("Показывает текущий трек из Яндекс Музыки с кнопками управления.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
