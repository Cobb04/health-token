import CoreGraphics

struct HealthConsolePresentation: Equatable {
    static let overviewSize = CGSize(width: 554, height: 260)

    var preferredSize: CGSize { Self.overviewSize }
}

enum HealthConsoleWellbeingState: Equatable {
    case depleted
    case steady
    case thriving

    static func resolve(
        waterProgress: Double,
        movementProgress: Double?
    ) -> Self {
        let score = min(waterProgress, movementProgress ?? waterProgress)
        if score >= 0.8 {
            return .thriving
        }
        if score >= 0.375 {
            return .steady
        }
        return .depleted
    }
}
