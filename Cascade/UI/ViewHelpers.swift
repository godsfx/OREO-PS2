import SwiftUI
import UIKit

// MARK: - Brand Colors

extension Color {
    static let cascadeBlue = Color(red: 0.14, green: 0.45, blue: 0.95)
}

// MARK: - iOS-version-gated view modifiers

/// Applies `.symbolEffect(.pulse)` on iOS 17+ and is a no-op on earlier versions.
struct PulseIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content.symbolEffect(.pulse)
        } else {
            content
        }
    }
}

// MARK: - UIActivityViewController wrapper

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Identifiable URL wrapper for .sheet(item:)

struct IdentifiableURL: Identifiable {
    let id  = UUID()
    let url: URL
}

extension URL {
    var identifiable: IdentifiableURL { IdentifiableURL(url: self) }
}
