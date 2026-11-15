import Foundation

@main
struct ScrollTargetTests {
    static func main() {
        func check(_ actual: ScrollTargetState, _ expected: ScrollTargetState, _ message: String) {
            guard actual == expected else { fputs("FAIL: \(message): \(actual)\n", stderr); exit(1) }
        }
        check(ScrollTargetEvidence().state, .unknown, "No evidence cannot imply non-scrollable")
        var evidence = ScrollTargetEvidence()
        evidence.reachedWindowOrRoot = true
        check(evidence.state, .notScrollable, "Complete ordinary button/window ancestry has no scrolling ancestor")
        evidence.uncertainContainer = true
        check(evidence.state, .unknown, "Custom web/canvas content must preserve fallback")
        evidence.confirmedVerticalOverflow = true
        check(evidence.state, .scrollable, "Explicit overflow takes precedence over custom content")
        evidence = ScrollTargetEvidence()
        evidence.reachedWindowOrRoot = true
        evidence.incompleteAncestry = true
        check(evidence.state, .unknown, "Timeout or truncated ancestry must preserve fallback")
        evidence.confirmedVerticalOverflow = true
        check(evidence.state, .scrollable, "Enabled vertical scrollbar confirms a target")
        print("PASS: conservative scroll target evidence classification, custom-content fallback, timeout/truncation, positive overflow precedence. AX application interoperability needs signed-host device testing.")
    }
}
