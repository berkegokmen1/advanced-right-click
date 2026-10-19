import Foundation

// Shared by the visual timeline and its editable time readouts.
struct PreviewRange {
    let duration: Double
    let maximumLength: Double
    var minimumLength: Double { min(0.04, duration) }
    func start(_ proposed: Double, end: Double) -> Double {
        max(max(0, end - maximumLength), min(proposed, end - minimumLength))
    }
    func end(_ proposed: Double, start: Double) -> Double {
        min(duration, min(start + maximumLength, max(start + minimumLength, proposed)))
    }
    static func timestamp(_ seconds: Double) -> String {
        let hundredths = Int((min(Double(Int.max / 1000), max(0, seconds.isFinite ? seconds : 0)) * 100).rounded())
        return String(format: "%02d:%02d.%02d", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
    }
    static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value.isFinite, value >= 0 else { return nil }
            if index > 0 && value >= 60 { return nil }
            total = total * 60 + value
            guard total.isFinite else { return nil }
        }
        return total
    }
}
