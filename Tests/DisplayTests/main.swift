import Foundation

func monitor(_ id: UInt32, _ x: Double, _ y: Double, _ w: Double = 1920, _ h: Double = 1080) -> RemoteDisplay {
    RemoteDisplay(id: id, name: "Display \(id)", width: Int(w), height: Int(h), frame: DisplayFrame(x: x, y: y, width: w, height: h))
}
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ reason: String) {
    precondition(condition(), reason); checks += 1
}
let center = monitor(1, 0, 0)
let layout = [center, monitor(2, -1920, 0), monitor(3, 1920, 120), monitor(4, 0, -1080), monitor(5, 0, 1080)]
check(DisplayNavigation.neighbor(from: 1, toward: .left, displays: layout)?.id == 2, "Negative origin: left screen")
check(DisplayNavigation.neighbor(from: 1, toward: .right, displays: layout)?.id == 3, "Offset right screen")
check(DisplayNavigation.neighbor(from: 1, toward: .up, displays: layout)?.id == 4, "Top-left coordinate origin: upper screen")
check(DisplayNavigation.neighbor(from: 1, toward: .down, displays: layout)?.id == 5, "Screen below")
check(DisplayNavigation.neighbor(from: 2, toward: .left, displays: layout) == nil, "No wrap at outer edge")
check(DisplayNavigation.neighbor(from: 1, toward: .right, displays: [center, monitor(9, 5, -1080)]) == nil, "A slightly offset upper screen is not a right neighbor")
check(DisplayNavigation.neighbor(from: 1, toward: .right, displays: [center, monitor(6, 1920, -1800, 1080, 3000)])?.id == 6, "Tall adjacent portrait display shares an edge")
check(DisplayNavigation.neighbor(from: 1, toward: .right, displays: [center, monitor(6, 0, 0)]) == nil, "Mirror never becomes a destination")
check(DisplayNavigation.neighbor(from: 1, toward: .right, displays: [center, monitor(7, 3840, 0), monitor(6, 1920, 0)])?.id == 6, "Nearest display wins")
check(DisplayNavigation.neighbor(from: 1, toward: .right, displays: [center, monitor(6, 1920, 3000), monitor(7, 1920, 0)])?.id == 7, "Aligned neighbor beats diagonal")
check(DisplayNavigation.ordered(displays: layout).map(\.id) == [2, 4, 1, 5, 3], "App pages follow left-to-right columns and top-to-bottom ties")
check(DisplayNavigation.ordered(displays: layout.reversed()).map(\.id) == [2, 4, 1, 5, 3], "Ordering does not depend on host enumeration")
let mirrored = [monitor(12, 0, 0), monitor(9, 0, 0)]
check(DisplayNavigation.ordered(displays: mirrored).map(\.id) == [9, 12], "Mirrored display ties have stable ID ordering")
let portrait = monitor(15, -1080, -500, 1080, 1920)
check(DisplayNavigation.ordered(displays: [center, portrait]).map(\.id) == [15, 1], "Portrait monitor with negative origin remains leftmost")
let unequal = [monitor(22, 0, 0, 4000, 1080), monitor(21, 1000, 0, 1080, 1920)]
check(DisplayNavigation.ordered(displays: unequal).map(\.id) == [21, 22], "Spatial order uses display centers for unequal widths")
let missing = RemoteDisplay(id: 50, name: "Legacy", width: 1920, height: 1080)
let invalid = RemoteDisplay(id: 40, name: "Invalid", width: 1920, height: 1080, frame: DisplayFrame(x: .infinity, y: 0, width: 1920, height: 1080))
check(DisplayNavigation.ordered(displays: [missing, center, invalid]).map(\.id) == [1, 40, 50], "Unknown geometry follows spatial displays with deterministic fallback")
check(DisplayNavigation.ordered(displays: []).isEmpty, "Empty display list orders safely")
check(DisplayNavigation.ordered(displays: [portrait]).map(\.id) == [15], "Single display remains unchanged")
let encoder = PropertyListEncoder(), decoder = PropertyListDecoder()
let encoded = try encoder.encode(RemoteDisplay(id: 3, name: "Portrait", width: 1080, height: 1920, frame: DisplayFrame(x: -1080, y: -500, width: 1080, height: 1920), isCurrent: true))
let decoded = try decoder.decode(RemoteDisplay.self, from: encoded)
check(decoded.frame?.x == -1080 && decoded.isCurrent == true, "Physical arrangement survives wire encoding")
let legacy = try PropertyListSerialization.data(fromPropertyList: ["id": 1, "name": "Legacy", "width": 1920, "height": 1080], format: .binary, options: 0)
let old = try decoder.decode(RemoteDisplay.self, from: legacy)
check(old.frame == nil && old.isCurrent == nil, "Older display metadata still decodes for menu selection")
check(!DisplayFrame(x: .nan, y: 0, width: 1, height: 1).isValid, "Invalid geometry rejected")
print("PASS: \(checks) display arrangement, app-page ordering, and wire compatibility checks")
