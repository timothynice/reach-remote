import Foundation

/// A spring-centered scroll control: displacement chooses speed, elapsed time
/// chooses distance. Positive displacement yields downward scroll distance.
public enum ScrollRailDynamics {
    public static let deadZone = 6.0
    public static let maximumVelocity = 2400.0
    public static let maximumElapsed = 0.05

    /// `travel` is the usable distance from the touch origin to either rail end.
    /// Dead-zone removal makes motion continuous at six points; the power curve
    /// leaves most of the rail available for precise, slower scrolling.
    public static func velocity(displacement: Double, travel: Double) -> Double {
        guard displacement.isFinite, travel.isFinite, travel > deadZone else { return 0 }
        let distance = min(abs(displacement), travel)
        guard distance > deadZone else { return 0 }
        let normalized = (distance - deadZone) / (travel - deadZone)
        let speed = pow(normalized, 1.7) * maximumVelocity
        return displacement < 0 ? -speed : speed
    }

    /// Frame-independent integration with a bounded time step prevents a delayed
    /// display callback or foreground resume from producing a large scroll jump.
    public static func delta(velocity: Double, elapsed: Double) -> Double {
        guard velocity.isFinite, elapsed.isFinite, elapsed > 0 else { return 0 }
        let boundedVelocity = min(max(velocity, -maximumVelocity), maximumVelocity)
        return boundedVelocity * min(elapsed, maximumElapsed)
    }
}

/// Carries subpixel distance between timer ticks so integer scroll events retain
/// slow, sustained motion. Reset at every release, cancellation or session end.
public struct ScrollRailAccumulator {
    private var remainder = 0.0
    public init() {}

    /// Returns signed whole pixels; elapsed-time and velocity bounds match the rail.
    public mutating func step(velocity: Double, elapsed: Double) -> Double {
        guard velocity.isFinite, elapsed.isFinite, elapsed > 0 else { return 0 }
        let distance = remainder + ScrollRailDynamics.delta(velocity: velocity, elapsed: elapsed)
        // Tolerance corrects binary summation at an integer boundary, e.g. sixty
        // 1/12-pixel steps, without discarding or rounding ordinary fractions.
        let nearest = distance.rounded()
        let whole = abs(distance - nearest) < 1e-10 ? nearest : distance.rounded(.towardZero)
        remainder = distance - whole
        if abs(remainder) < 1e-10 { remainder = 0 }
        return whole
    }

    public mutating func reset() { remainder = 0 }
}
