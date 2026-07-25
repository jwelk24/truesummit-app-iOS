import Foundation
import SwiftData
import Testing
@testable import Summit

/// Household settle-up balances: positive means the household owes you.
@MainActor
struct SettleUpTests {

    private let household = UUID()
    private let me = UUID()
    private let partner = UUID()

    private func expense(payer: UUID, amount: Decimal, payerShare: Decimal) -> SharedExpenseModel {
        SharedExpenseModel(householdID: household, title: "e", amount: amount,
                           payerUserID: payer, payerShare: payerShare)
    }

    @Test func payingAFiftyFiftyExpenseIsOwedHalf() {
        let e = expense(payer: me, amount: 100, payerShare: 50)
        let balance = SettleUp.netBalance(expenses: [e], settlements: [], me: me, memberCount: 2)
        #expect(balance == 50)
    }

    @Test func partnersExpenseMeansIOweMyShare() {
        let e = expense(payer: partner, amount: 100, payerShare: 50)
        let balance = SettleUp.netBalance(expenses: [e], settlements: [], me: me, memberCount: 2)
        #expect(balance == -50)
    }

    @Test func unevenSplitUsesThePayerShare() {
        // I paid $90 but my share is only $30 — the household owes me $60.
        let e = expense(payer: me, amount: 90, payerShare: 30)
        let balance = SettleUp.netBalance(expenses: [e], settlements: [], me: me, memberCount: 2)
        #expect(balance == 60)
    }

    @Test func threePersonHouseholdSplitsTheRemainderAmongOthers() {
        // Partner paid $90, their share $30 → $60 owed by the other two: $30 each.
        let e = expense(payer: partner, amount: 90, payerShare: 30)
        let balance = SettleUp.netBalance(expenses: [e], settlements: [], me: me, memberCount: 3)
        #expect(balance == -30)
    }

    @Test func settlementZeroesTheBalance() {
        // I owe $50, then I pay a $50 settlement.
        let e = expense(payer: partner, amount: 100, payerShare: 50)
        let s = SettlementModel(householdID: household, fromUserID: me, toUserID: partner, amount: 50)
        let balance = SettleUp.netBalance(expenses: [e], settlements: [s], me: me, memberCount: 2)
        #expect(balance == 0)
    }

    @Test func receivingASettlementClearsWhatIWasOwed() {
        let e = expense(payer: me, amount: 100, payerShare: 50)
        let s = SettlementModel(householdID: household, fromUserID: partner, toUserID: me, amount: 50)
        let balance = SettleUp.netBalance(expenses: [e], settlements: [s], me: me, memberCount: 2)
        #expect(balance == 0)
    }

    @Test func mixedHistoryNetsOut() {
        let expenses = [
            expense(payer: me, amount: 200, payerShare: 100),      // +100
            expense(payer: partner, amount: 60, payerShare: 30),   // -30
        ]
        let balance = SettleUp.netBalance(expenses: expenses, settlements: [], me: me, memberCount: 2)
        #expect(balance == 70)
    }
}
