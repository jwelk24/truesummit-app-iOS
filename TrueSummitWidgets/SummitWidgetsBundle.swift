import WidgetKit
import SwiftUI

@main
struct SummitWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SafeToSpendWidget()
        HealthScoreWidget()
        QuickLogWidget()
        QuickAddWidget()
        NetWorthWidget()
        BudgetRemainingWidget()
        UpcomingBillsWidget()
        SummitWidgetsControl()
        SpendingTodayLiveActivity()
    }
}
