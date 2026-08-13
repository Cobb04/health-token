import AppKit
import CoreGraphics
import SwiftUI

struct HealthConsolePresentation: Equatable {
    enum Surface: Equatable {
        case overview
        case water
    }

    enum Action: Equatable {
        case selectWater
        case quickSip
        case collapseWater
    }

    private(set) var surface: Surface

    init(surface: Surface = .overview) {
        self.surface = surface
    }

    var preferredSize: CGSize {
        switch surface {
        case .overview:
            CGSize(width: 554, height: 260)
        case .water:
            CGSize(width: 554, height: 565)
        }
    }

    mutating func send(_ action: Action) {
        switch action {
        case .selectWater:
            surface = surface == .water ? .overview : .water
        case .quickSip:
            break
        case .collapseWater:
            surface = .overview
        }
    }
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

@MainActor
enum HealthConsoleWindowAppearance {
    static func apply(to window: NSWindow) {
        // MenuBarExtra supplies its own rounded mask. A second content clip exposes
        // the system material and shadow as a gray halo around the black console.
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
    }
}

struct HealthConsoleWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(for: nsView)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            HealthConsoleWindowAppearance.apply(to: window)
        }
    }
}
