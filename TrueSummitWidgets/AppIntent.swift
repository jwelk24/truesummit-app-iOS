//
//  AppIntent.swift
//  SummitWidgets
//
//  Created by Jayson Welker on 6/17/26.
//

import WidgetKit
import AppIntents

/// User-selectable widget background, chosen per widget via long-press →
/// Edit Widget. `.mountain` draws the live Summit scene; `.plain` uses the
/// system material. Only applies to home-screen (system) families; accessory
/// families always render plain.
enum WidgetBackgroundStyle: String, AppEnum {
    case mountain
    case plain

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Background" }

    static var caseDisplayRepresentations: [WidgetBackgroundStyle: DisplayRepresentation] {
        [
            .mountain: DisplayRepresentation(title: "Mountain", subtitle: "Live Summit scene"),
            .plain: DisplayRepresentation(title: "Plain", subtitle: "System background"),
        ]
    }
}

/// Configuration for Summit's informational widgets: just the background style.
struct SummitBackgroundIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Widget Background" }
    static var description: IntentDescription { IntentDescription("Choose how this widget looks.") }

    @Parameter(title: "Background", default: .mountain)
    var background: WidgetBackgroundStyle
}
