import ObjectiveC.runtime
import SwiftUI
import UIKit

// MARK: - Brand Colors

extension Color {
    static let cascadeBlue = Color(red: 0.14, green: 0.45, blue: 0.95)
}

// MARK: - Runtime Guard Against Non-Plist UserDefaults Crashes (_CFPrefsValidateValueForKey)

enum UserDefaultsSafeGuard {
    static let install: Void = {
        let cls = UserDefaults.self
        let origSel = NSSelectorFromString("setObject:forKey:")
        let swizSel = #selector(UserDefaults.cascade_safeSetObject(_:forKey:))
        guard let origMethod = class_getInstanceMethod(cls, origSel),
              let swizMethod = class_getInstanceMethod(cls, swizSel) else {
            return
        }
        method_exchangeImplementations(origMethod, swizMethod)
    }()

    static func sanitize(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if value is NSNull {
            return nil
        }
        if let url = value as? URL {
            return (try? NSKeyedArchiver.archivedData(withRootObject: url, requiringSecureCoding: true)) ?? url.path
        }
        if let uuid = value as? UUID {
            return uuid.uuidString
        }
        if let dict = value as? [String: Any] {
            var clean: [String: Any] = [:]
            for (k, v) in dict {
                if let sanitized = sanitize(v) {
                    clean[k] = sanitized
                }
            }
            return clean
        }
        if let array = value as? [Any] {
            return array.compactMap { sanitize($0) }
        }
        if PropertyListSerialization.propertyList(value, isValidFor: .binary) {
            return value
        }
        return String(describing: value)
    }
}

private extension UserDefaults {
    @objc(cascade_safeSetObject:forKey:)
    func cascade_safeSetObject(_ value: Any?, forKey defaultName: String) {
        guard !defaultName.isEmpty else { return }
        let safeValue = UserDefaultsSafeGuard.sanitize(value)
        self.cascade_safeSetObject(safeValue, forKey: defaultName)
    }
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
