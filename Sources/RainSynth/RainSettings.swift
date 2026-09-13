import Foundation

/// Everything the listener can change. All values are 0...1.
public struct RainSettings: Codable, Equatable, Sendable {
    /// Output level.
    public var volume: Double
    /// Density and loudness of the steady rain wash.
    public var rain: Double
    /// How many close, individual drops you hear.
    public var drops: Double
    /// Low-end body, like heavy rain on a roof.
    public var rumble: Double
    /// Dark (muffled, behind a window) to bright (open air).
    public var tone: Double
    /// Gusting wind, which also makes the rain surge.
    public var wind: Double
    /// How often thunder rolls in. 0 is never.
    public var thunder: Double

    public init(
        volume: Double = 0.6,
        rain: Double = 0,
        drops: Double = 0,
        rumble: Double = 0,
        tone: Double = 0.5,
        wind: Double = 0,
        thunder: Double = 0
    ) {
        self.volume = volume
        self.rain = rain
        self.drops = drops
        self.rumble = rumble
        self.tone = tone
        self.wind = wind
        self.thunder = thunder
    }

    public static let `default` = RainPreset.steady.apply(to: RainSettings())
}

public struct RainPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let rain: Double
    public let drops: Double
    public let rumble: Double
    public let tone: Double
    public let wind: Double
    public let thunder: Double

    /// Returns `settings` with this preset's sound, keeping the volume.
    public func apply(to settings: RainSettings) -> RainSettings {
        var result = settings
        result.rain = rain
        result.drops = drops
        result.rumble = rumble
        result.tone = tone
        result.wind = wind
        result.thunder = thunder
        return result
    }

    public func matches(_ settings: RainSettings) -> Bool {
        apply(to: settings) == settings
    }

    public static func matching(_ settings: RainSettings) -> RainPreset? {
        all.first { $0.matches(settings) }
    }

    public static let drizzle = RainPreset(id: "drizzle", name: "Drizzle", rain: 0.3, drops: 0.3, rumble: 0.05, tone: 0.6, wind: 0.05, thunder: 0)
    public static let steady = RainPreset(id: "steady", name: "Steady rain", rain: 0.55, drops: 0.4, rumble: 0.25, tone: 0.55, wind: 0.1, thunder: 0)
    public static let downpour = RainPreset(id: "downpour", name: "Downpour", rain: 0.9, drops: 0.55, rumble: 0.55, tone: 0.5, wind: 0.3, thunder: 0)
    public static let roof = RainPreset(id: "roof", name: "Rain on a roof", rain: 0.6, drops: 0.7, rumble: 0.7, tone: 0.3, wind: 0.05, thunder: 0)
    public static let window = RainPreset(id: "window", name: "Behind a window", rain: 0.5, drops: 0.15, rumble: 0.35, tone: 0.1, wind: 0.15, thunder: 0)
    public static let storm = RainPreset(id: "storm", name: "Thunderstorm", rain: 0.8, drops: 0.45, rumble: 0.5, tone: 0.45, wind: 0.45, thunder: 0.6)

    public static let all: [RainPreset] = [drizzle, steady, downpour, roof, window, storm]
}
