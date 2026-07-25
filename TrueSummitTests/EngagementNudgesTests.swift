import Foundation
import Testing
@testable import Summit

@MainActor
struct EngagementNudgesTests {

    // MARK: Weekly content

    @Test func weeklyContentPointsAtInboxWhenItemsNeedReview() {
        let content = EngagementNudgesService.weeklyContent(newCount: 12, reviewCount: 3)
        #expect(content.destination == .reviewInbox)
        #expect(content.body == "12 new transactions this week — 3 need a category.")
    }

    @Test func weeklyContentSingularForms() {
        let content = EngagementNudgesService.weeklyContent(newCount: 1, reviewCount: 1)
        #expect(content.body == "1 new transaction this week — 1 needs a category.")
    }

    @Test func weeklyContentWithOnlyStaleReviewItems() {
        let content = EngagementNudgesService.weeklyContent(newCount: 0, reviewCount: 2)
        #expect(content.destination == .reviewInbox)
        #expect(content.body == "2 transactions still need a category.")
    }

    @Test func weeklyContentAllCategorizedPointsAtWeeklyReview() {
        let content = EngagementNudgesService.weeklyContent(newCount: 8, reviewCount: 0)
        #expect(content.destination == .weeklyReview)
        #expect(content.body.contains("8 new transactions"))
    }

    @Test func weeklyContentQuietWeekStillInvitesReview() {
        let content = EngagementNudgesService.weeklyContent(newCount: 0, reviewCount: 0)
        #expect(content.destination == .weeklyReview)
    }

    // MARK: Monthly content

    @Test func monthlyContentNamesTheMonthBeingSummarized() {
        var comps = DateComponents(year: 2026, month: 6, day: 15)
        comps.calendar = Calendar.current
        let midJune = comps.date!
        let content = EngagementNudgesService.monthlyContent(for: midJune)
        #expect(content.title.contains("June"))
        #expect(content.destination == .monthRecap)
    }

    // MARK: Fire dates

    @Test func weeklyFireDateIsNextSundayNine() {
        let cal = Calendar.current
        let now = Date()
        let fire = EngagementNudgesService.nextWeeklyFireDate(after: now, calendar: cal)

        #expect(fire > now)
        #expect(cal.component(.weekday, from: fire) == 1)
        #expect(cal.component(.hour, from: fire) == 9)
        // Within the coming week, never further out.
        #expect(fire.timeIntervalSince(now) <= 7 * 24 * 3600)
    }

    @Test func monthlyFireDateIsFirstOfNextMonthNine() {
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 13, hour: 12)
        comps.calendar = cal
        let now = comps.date!
        let fire = EngagementNudgesService.nextMonthlyFireDate(after: now, calendar: cal)

        #expect(cal.component(.day, from: fire) == 1)
        #expect(cal.component(.hour, from: fire) == 9)
        #expect(cal.component(.month, from: fire) == 8)
        #expect(cal.component(.year, from: fire) == 2026)
    }

    @Test func monthlyFireDateRollsOverYearEnd() {
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 12, day: 20)
        comps.calendar = cal
        let now = comps.date!
        let fire = EngagementNudgesService.nextMonthlyFireDate(after: now, calendar: cal)

        #expect(cal.component(.month, from: fire) == 1)
        #expect(cal.component(.year, from: fire) == 2027)
    }
}
