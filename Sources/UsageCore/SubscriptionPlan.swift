import Foundation

/// Display classification from Claude's declared account metadata, never usage
/// percentages, email addresses, or presumed capacity multipliers.
public enum SubscriptionPlan: String, Codable, Hashable, Sendable {
    case pro
    case max5x
    case max20x
    case maxUnknown
    case teamPremium
    case teamUnknown
    case enterprise
    case unknown

    public init(subscriptionType: String?, rateLimitTier: String?, seatTier: String? = nil) {
        // Verified against public Claude Code 2.1.270: its Max classifier uses
        // these exact rate-limit identifiers. isTeamPremiumSubscriber uses the
        // same 5x identifier only when subscriptionType is explicitly "team".
        switch subscriptionType {
        case "max":
            switch rateLimitTier {
            case "default_claude_max_5x": self = .max5x
            case "default_claude_max_20x": self = .max20x
            default: self = .maxUnknown
            }
        case "team":
            self = rateLimitTier == "default_claude_max_5x" ? .teamPremium : .teamUnknown
        case "pro": self = .pro
        case "enterprise": self = .enterprise
        default: self = .unknown
        }
        // seatTier is retained by Credentials for future verified mappings.
        // Other Team rates or seat identifiers do not prove a Standard seat.
    }

    public var displayName: String {
        switch self {
        case .pro: return "Pro"
        case .max5x: return "Max 5×"
        case .max20x: return "Max 20×"
        case .maxUnknown: return "Max (tier unknown)"
        case .teamPremium: return "Team Premium"
        case .teamUnknown: return "Team (tier unknown)"
        case .enterprise: return "Enterprise"
        case .unknown: return "Plan unknown"
        }
    }

    public var explanation: String {
        switch self {
        case .maxUnknown: return "Claude reports Max, but its subtype is missing or unrecognized."
        case .teamUnknown: return "Claude reports Team, but the available metadata does not identify a verified Standard or Premium seat."
        case .unknown: return "The available Claude credential does not identify a recognized subscription plan."
        default: return "Based on Claude's subscription and rate-limit metadata."
        }
    }
}
