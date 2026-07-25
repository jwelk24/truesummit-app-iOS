import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center control that opens Summit straight to "Add Expense" via the
/// `summit://add` deep link.
struct SummitWidgetsControl: ControlWidget {
    static let kind: String = "com.welker.Summit.QuickAddControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "summit://add")!)) {
                Label("Add Expense", systemImage: "plus.circle.fill")
            }
        }
        .displayName("Add Expense")
        .description("Quickly log an expense in Summit.")
    }
}
