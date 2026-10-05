import Foundation

/// Swift Charts' automatic ticks and domains, as measured against it
/// (`PiChartTicksTests`, `PiChartParityTests`).
///
/// Numbers: steps of 1, 2 or 5 times a power of ten, and 25, 250… (2.5 times
/// a power of ten of at least 10). An automatic domain from zero ends on the
/// first multiple of the step at or past the data; of the steps that give it
/// two intervals or more, the one whose intervals are nearest `desiredCount`
/// less one (3.5 by default) wins, its coverage of the data breaking ties.
///
/// Dates: calendar units from a second to a year, each counted from the
/// domain's start rounded down to its base unit (the second, minute, hour,
/// day, the locale's week or the month); the unit whose ticks inside the
/// domain come nearest 4.25 wins, the smaller one on a tie. `desiredCount`
/// does not change the choice (measured: 4 and the default choose alike).
enum PiChartTicks {
    /// The step and the number of intervals Swift Charts takes for an
    /// automatic domain from zero to `top`.
    static func numberStep(top: Double, desiredCount: Int?) -> (step: Double, intervals: Int) {
        guard top > 0, top.isFinite else { return (1, 1) }
        let target = Double(desiredCount ?? 0) - 1
        let wanted = desiredCount == nil ? 3.5 : target
        var best: (score: Double, step: Double, intervals: Int)?
        let lowest = Int(floor(log10(top))) - 3
        for power in lowest...(lowest + 6) {
            for factor in [1, 2, 2.5, 5] as [Double] {
                if factor == 2.5 && power < 1 { continue }
                let step = factor * pow(10, Double(power))
                let intervals = Int(ceil(top / step - 1e-9))
                guard intervals >= 2, intervals <= 12 else { continue }
                let score = top / (Double(intervals) * step) - abs(Double(intervals) - wanted)
                if let current = best, score < current.score + 1e-12,
                   !(abs(score - current.score) < 1e-12 && step > current.step) { continue }
                best = (score, step, intervals)
            }
        }
        guard let best else { return (top, 1) }
        return (clean(best.step), best.intervals)
    }

    /// The ticks over a fixed `domain`: every multiple of the step Swift
    /// Charts would take for it inside it.
    static func numbers(_ domain: ClosedRange<Double>, desiredCount: Int?) -> [Double] {
        let span = domain.upperBound - max(0, domain.lowerBound)
        let step = numberStep(top: span > 0 ? span : domain.upperBound - domain.lowerBound, desiredCount: desiredCount).step
        return multiples(of: step, in: domain)
    }

    /// Every multiple of `step` inside `domain`.
    static func multiples(of step: Double, in domain: ClosedRange<Double>) -> [Double] {
        guard step > 0 else { return [domain.lowerBound] }
        let first = ceil(domain.lowerBound / step - 1e-9), last = floor(domain.upperBound / step + 1e-9)
        guard last >= first, last - first < 10_000 else { return [] }
        return stride(from: first, through: last, by: 1).map { clean($0 * step) + 0 }
    }

    /// An automatic domain from zero, widened to its ticks, and the step
    /// its ticks are on.
    static func automaticDomain(_ lower: Double, _ upper: Double, desiredCount: Int?, includesZero: Bool = true) -> (domain: ClosedRange<Double>, step: Double) {
        if !includesZero, upper > lower, lower > 0 || upper < 0 {
            // Off zero: the data's own span, widened to the step's multiples.
            let step = numberStep(top: upper - lower, desiredCount: desiredCount).step
            return (clean(floor(lower / step) * step)...clean(ceil(upper / step) * step), step)
        }
        let top = max(abs(lower), abs(upper))
        guard top > 0 else { return (0...1, numberStep(top: 1, desiredCount: desiredCount).step) }
        let (step, intervals) = numberStep(top: top, desiredCount: desiredCount)
        let end = clean(step * Double(intervals))
        let domain = lower < 0 && upper <= 0 ? -end...0 : lower < 0 ? -clean(ceil(-lower / step) * step)...end : 0...end
        return (domain, step)
    }

    /// Swift Charts' default text for a number on an axis.
    static func numberLabel(_ value: Double) -> String {
        value.formatted(.number)
    }

    /// Rounds away the binary noise of `n × step` (0.30000000000000004).
    static func clean(_ value: Double) -> Double {
        guard value != 0, value.isFinite else { return value == 0 ? 0 : value }
        let magnitude = pow(10, 12 - floor(log10(abs(value))))
        return (value * magnitude).rounded() / magnitude
    }

    // MARK: Dates

    /// A calendar step: `count` of a base unit.
    enum Base: Equatable { case second, minute, hour, day, week, month }
    struct Unit: Equatable { let base: Base; let count: Int }
    static let units: [Unit] = [
        Unit(base: .second, count: 1), Unit(base: .second, count: 5), Unit(base: .second, count: 15), Unit(base: .second, count: 30),
        Unit(base: .minute, count: 1), Unit(base: .minute, count: 5), Unit(base: .minute, count: 15), Unit(base: .minute, count: 30),
        Unit(base: .hour, count: 1), Unit(base: .hour, count: 3), Unit(base: .hour, count: 6), Unit(base: .hour, count: 12),
        Unit(base: .day, count: 1), Unit(base: .day, count: 2), Unit(base: .week, count: 1), Unit(base: .week, count: 2),
        Unit(base: .month, count: 1), Unit(base: .month, count: 2), Unit(base: .month, count: 3), Unit(base: .month, count: 6),
        Unit(base: .month, count: 12),
    ]
    /// The tick count Swift Charts comes nearest to.
    static let dateTarget = 4.25

    /// Date ticks over `domain` (seconds since the reference date).
    static func dates(_ domain: ClosedRange<Double>, calendar: Calendar = .current) -> [Double] {
        guard domain.upperBound > domain.lowerBound else { return [] }
        var best: (score: Double, ticks: [Double])?
        for unit in units {
            // A unit far too small for the span would count thousands.
            if approximateSeconds(unit) * 400 < domain.upperBound - domain.lowerBound { continue }
            let ticks = dates(domain, unit: unit, calendar: calendar)
            guard !ticks.isEmpty else { continue }
            let score = abs(Double(ticks.count) - dateTarget)
            if best == nil || score < best!.score - 1e-9 { best = (score, ticks) }
        }
        return best?.ticks ?? []
    }

    /// The ticks of one unit inside `domain`, counted from the domain's start
    /// rounded down to the unit's base.
    static func dates(_ domain: ClosedRange<Double>, unit: Unit, calendar: Calendar) -> [Double] {
        let from = Date(timeIntervalSinceReferenceDate: domain.lowerBound)
        var date = start(from, base: unit.base, calendar: calendar)
        var ticks: [Double] = []
        var steps = 0
        while date.timeIntervalSinceReferenceDate <= domain.upperBound + 1e-6, steps < 1_000 {
            if date.timeIntervalSinceReferenceDate >= domain.lowerBound - 1e-6 { ticks.append(date.timeIntervalSinceReferenceDate) }
            steps += 1
            guard let next = advance(start(from, base: unit.base, calendar: calendar), by: unit, times: steps, calendar: calendar) else { break }
            date = next
        }
        return ticks
    }

    static func approximateSeconds(_ unit: Unit) -> Double {
        let base: Double
        switch unit.base {
        case .second: base = 1
        case .minute: base = 60
        case .hour: base = 3_600
        case .day: base = 86_400
        case .week: base = 604_800
        case .month: base = 2_629_800
        }
        return base * Double(unit.count)
    }

    /// `date` rounded down to its second, minute, hour, day, week (the
    /// calendar's first weekday) or month.
    static func start(_ date: Date, base: Base, calendar: Calendar) -> Date {
        switch base {
        case .second: return Date(timeIntervalSinceReferenceDate: floor(date.timeIntervalSinceReferenceDate))
        case .minute: return calendar.dateInterval(of: .minute, for: date)?.start ?? date
        case .hour: return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        case .day: return calendar.startOfDay(for: date)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        case .month: return calendar.dateInterval(of: .month, for: date)?.start ?? date
        }
    }

    /// `origin` plus `times` steps of `unit`, on the calendar.
    static func advance(_ origin: Date, by unit: Unit, times: Int, calendar: Calendar) -> Date? {
        let n = unit.count * times
        switch unit.base {
        case .second: return origin.addingTimeInterval(Double(n))
        case .minute: return origin.addingTimeInterval(Double(n) * 60)
        case .hour: return calendar.date(byAdding: .hour, value: n, to: origin)
        case .day: return calendar.date(byAdding: .day, value: n, to: origin)
        case .week: return calendar.date(byAdding: .day, value: 7 * n, to: origin)
        case .month: return calendar.date(byAdding: .month, value: n, to: origin)
        }
    }
}
