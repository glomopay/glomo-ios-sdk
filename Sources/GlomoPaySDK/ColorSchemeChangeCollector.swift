import Foundation

/// Collects one answer per WebView after a colour-scheme change, then reports once.
///
/// Its own type because the three-way outcome is the whole value of the signal and is easy to
/// collapse by accident. A page that never defined `glomoSetColorScheme` is a web-side slip; a
/// WebView that never answered is our own probe failing. Folding the second into the first would
/// let a torn-down WebView read as a site-wide outage.
///
/// Main-actor only: `evaluateJavaScript` completions arrive there, and so does ``timeOut()``.
@MainActor
final class ColorSchemeChangeCollector {
    private let targets: [String]
    private let onComplete: ([String], [String]) -> Void
    private var answers: [String: Bool] = [:]
    private var reported = false

    init(targets: [String], onComplete: @escaping ([String], [String]) -> Void) {
        self.targets = targets
        self.onComplete = onComplete
    }

    /// Records one WebView's answer. Completes as soon as every target has answered.
    ///
    /// An answer from a surface that was never asked is accepted here and dropped by `complete`,
    /// which reports out of `targets` rather than out of what arrived. One filter, not two.
    func record(target: String, applied: Bool) {
        guard !reported else { return }
        answers[target] = applied
        if targets.allSatisfy({ answers[$0] != nil }) { complete() }
    }

    /// Reports with whatever arrived. Anything missing is unprobed, not a miss.
    func timeOut() {
        guard !reported else { return }
        complete()
    }

    private func complete() {
        reported = true
        onComplete(
            targets.filter { answers[$0] == true },
            targets.filter { answers[$0] == nil }
        )
    }
}
