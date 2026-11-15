import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
    checks += 1
}
func close(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.000001) -> Bool {
    abs(lhs - rhs) <= tolerance
}
let travel = 120.0
check(ScrollRailDynamics.velocity(displacement: 0, travel: travel) == 0, "Centered rail stays still")
for displacement in [-6.0, -3, 3, 6] {
    check(ScrollRailDynamics.velocity(displacement: displacement, travel: travel) == 0, "Dead zone stays still")
}
check(ScrollRailDynamics.velocity(displacement: 6.001, travel: travel) > 0, "Motion starts continuously beyond dead zone")
let edge = ScrollRailDynamics.velocity(displacement: travel, travel: travel)
check(edge == 2400, "Rail edge reaches maximum pixels per second")
check(ScrollRailDynamics.velocity(displacement: 10_000, travel: travel) == edge, "Displacement beyond rail is clamped")
check(ScrollRailDynamics.velocity(displacement: -10_000, travel: travel) == -edge, "Negative displacement is clamped symmetrically")
var prior = 0.0
for step in 0...120 {
    let forward = ScrollRailDynamics.velocity(displacement: Double(step), travel: travel)
    let backward = ScrollRailDynamics.velocity(displacement: -Double(step), travel: travel)
    check(forward >= prior, "Speed increases monotonically with displacement")
    check(close(forward, -backward), "Velocity curve is symmetric around center")
    prior = forward
}
let halfSpeed = ScrollRailDynamics.velocity(displacement: 6 + (travel - 6) / 2, travel: travel)
check(halfSpeed > 0 && halfSpeed < 1200, "Power easing preserves slow control near center")
check(close(halfSpeed, pow(0.5, 1.7) * 2400), "Curve follows requested power 1.7")
for invalid in [Double.nan, .infinity, -.infinity] {
    check(ScrollRailDynamics.velocity(displacement: invalid, travel: travel) == 0, "Invalid displacement cannot scroll")
    check(ScrollRailDynamics.velocity(displacement: 30, travel: invalid) == 0, "Invalid rail travel cannot scroll")
    check(ScrollRailDynamics.delta(velocity: invalid, elapsed: 1 / 30) == 0, "Invalid velocity cannot scroll")
    check(ScrollRailDynamics.delta(velocity: 2400, elapsed: invalid) == 0, "Invalid elapsed time cannot scroll")
}
for tinyTravel in [-100.0, 0, 3, 6] {
    check(ScrollRailDynamics.velocity(displacement: 30, travel: tinyTravel) == 0, "Degenerate rail geometry stays still")
}
check(ScrollRailDynamics.delta(velocity: 2400, elapsed: -1) == 0, "Negative elapsed time cannot scroll")
check(ScrollRailDynamics.delta(velocity: 2400, elapsed: 0) == 0, "Zero elapsed time cannot scroll")
check(ScrollRailDynamics.delta(velocity: 2400, elapsed: 5) == 120, "Resume delays are bounded to 50 milliseconds")
check(ScrollRailDynamics.delta(velocity: 999_999, elapsed: 1) == 120, "External velocity cannot exceed safe maximum")
check(ScrollRailDynamics.delta(velocity: -999_999, elapsed: 1) == -120, "Negative maximum is symmetric")
let steadySpeed = ScrollRailDynamics.velocity(displacement: 85, travel: travel)
let heldAt30 = (0..<30).reduce(0.0) { total, _ in total + ScrollRailDynamics.delta(velocity: steadySpeed, elapsed: 1.0 / 30) }
let heldAt60 = (0..<60).reduce(0.0) { total, _ in total + ScrollRailDynamics.delta(velocity: steadySpeed, elapsed: 1.0 / 60) }
check(close(heldAt30, steadySpeed), "Stationary held thumb keeps scrolling for a full second")
check(close(heldAt30, heldAt60), "Steady distance is independent of timer frequency")
let variableFrames = [0.01, 0.04, 0.02, 0.03]
let variableDistance = variableFrames.reduce(0.0) { $0 + ScrollRailDynamics.delta(velocity: steadySpeed, elapsed: $1) }
check(close(variableDistance, steadySpeed * 0.1), "Variable valid frame times integrate actual elapsed time")
check(ScrollRailDynamics.delta(velocity: 0, elapsed: 1 / 30) == 0, "Release to center stops further scrolling")
var positive = ScrollRailAccumulator()
var negative = ScrollRailAccumulator()
var positiveTotal = 0.0, negativeTotal = 0.0
for _ in 0..<60 {
    let forward = positive.step(velocity: 5, elapsed: 1.0 / 60)
    let backward = negative.step(velocity: -5, elapsed: 1.0 / 60)
    check(forward.rounded(.towardZero) == forward, "Accumulator emits whole pixels")
    check(forward == -backward, "Fractional accumulation is sign symmetric")
    positiveTotal += forward; negativeTotal += backward
}
check(positiveTotal == 5, "Five pixels per second survives sixty integer scroll ticks")
check(negativeTotal == -5, "Negative slow scroll retains fractional distance")
var resettable = ScrollRailAccumulator()
check(resettable.step(velocity: 1, elapsed: 0.05) == 0, "Subpixel initial event is retained")
for _ in 0..<9 { _ = resettable.step(velocity: 1, elapsed: 0.05) }
resettable.reset()
var afterReset = 0.0
for _ in 0..<10 { afterReset += resettable.step(velocity: 1, elapsed: 0.05) }
check(afterReset == 0, "Reset discards old session fractional carry")
var slower = ScrollRailAccumulator(), faster = ScrollRailAccumulator()
var distance30 = 0.0, distance60 = 0.0
for _ in 0..<30 { distance30 += slower.step(velocity: 17.3, elapsed: 1.0 / 30) }
for _ in 0..<60 { distance60 += faster.step(velocity: 17.3, elapsed: 1.0 / 60) }
check(abs(distance30 - distance60) <= 1, "Accumulation is frame-rate independent within one whole pixel")
check(abs(distance30 - 17.3) < 1, "Accumulated travel stays within one pixel of continuous distance")
var invalidAccumulator = ScrollRailAccumulator()
check(invalidAccumulator.step(velocity: .nan, elapsed: 1.0 / 60) == 0, "Invalid velocity cannot poison fractional carry")
check(invalidAccumulator.step(velocity: 5, elapsed: .infinity) == 0, "Invalid time cannot poison fractional carry")
var validAfterInvalid = 0.0
for _ in 0..<60 { validAfterInvalid += invalidAccumulator.step(velocity: 5, elapsed: 1.0 / 60) }
check(validAfterInvalid == 5, "Valid slow scroll resumes after invalid input")
var reversing = ScrollRailAccumulator()
for _ in 0..<9 { _ = reversing.step(velocity: 1, elapsed: 0.05) }
for _ in 0..<9 { _ = reversing.step(velocity: -1, elapsed: 0.05) }
check(reversing.step(velocity: 0, elapsed: 1.0 / 60) == 0, "Equal opposite fractional travel cancels without an event")
print("PASS: \(checks) scroll-rail velocity, fractional accumulation, time integration and invalid-input checks")
