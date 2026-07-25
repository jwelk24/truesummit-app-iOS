import Foundation
import SwiftData
@testable import Summit

/// Shared fixtures for the money-math suites.
enum TestSupport {
    /// Fresh in-memory store with the full app schema, so relationships
    /// (splits, allocations, goals) behave exactly as in production.
    @MainActor
    static func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SummitSharedStore.schema, configurations: config)
        return ModelContext(container)
    }

    /// A deterministic local date. Time defaults to noon so day-boundary
    /// math never flips with the machine's time zone.
    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var comps = DateComponents(year: year, month: month, day: day, hour: hour)
        comps.calendar = Calendar.current
        return comps.date!
    }
}
