import Foundation

/// «Скругление углов» of avatars: one value instead of «Квадратные аватары» + «Уровень» (owner,
/// 2026-10-27). "0" is Telegram's circle, "25"…"100" how far the shape goes from a circle towards a
/// square ("100" — square with slightly rounded corners). Foundation only: host-tested.
enum GGAvatarCorners {
    static let round = "0"
    static let options = ["0", "25", "50", "75", "100"]

    /// 0…1: how far from a circle; 0 for a circle and for anything unknown.
    static func squareness(_ value: String) -> Double {
        guard let number = Double(value) else {
            return 0.0
        }
        return max(0.0, min(1.0, number / 100.0))
    }

    static func isSquare(_ value: String) -> Bool {
        return GGAvatarCorners.squareness(value) > 0.0
    }

    /// The square levels "25"…"100" closest to `percent`.
    static func nearestSquareLevel(_ percent: Double) -> String {
        var best = "100"
        var bestDistance = Double.greatestFiniteMagnitude
        for option in GGAvatarCorners.options where option != GGAvatarCorners.round {
            let distance = abs((Double(option) ?? 100.0) - percent)
            if distance < bestDistance {
                best = option
                bestDistance = distance
            }
        }
        return best
    }

    /// Builds ≤ 185 stored «Квадратные аватары» (`interface.avatars.square`) and its level
    /// (`interface.avatars.squareness`, "25"…"100", absent = "100", the old default). nil: keep the
    /// default (round) — the switch was off or never touched.
    static func merged(square: Bool?, squareness: String?) -> String? {
        guard square == true else {
            return nil
        }
        guard let squareness = squareness, let percent = Double(squareness) else {
            return "100"
        }
        return GGAvatarCorners.nearestSquareLevel(percent)
    }

    /// The old Ghostgram: `FontCustomization.squareAvatarsInChatList` and `.avatarSquarenessLevel`
    /// (absent level = 100). nil: keep the default.
    static func fromLegacy(square: Bool?, level: Int?) -> String? {
        guard square == true else {
            return nil
        }
        return GGAvatarCorners.nearestSquareLevel(Double(level ?? 100))
    }
}
