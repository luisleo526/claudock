import Foundation

/// Compatibility facade for UI callers. Profile management never edits shell startup files.
public enum ProfileManager {
    public enum ManagementError: LocalizedError {
        case invalidName, reservedName, duplicateName, duplicateDirectory, missingProfile, protectedProfile, unresolvedProfile
        case directoryExists, invalidDirectory, invalidManagedFiles, concurrentChange, busy
        case unsupportedShellFile, ioFailure

        public var errorDescription: String? {
            switch self {
            case .invalidName: return "Use 1–40 letters, numbers, underscores, or hyphens, starting with a letter or number."
            case .reservedName: return "The names ‘default’ and ‘auto’ are reserved for the default account and automatic routing. Choose another name."
            case .duplicateName: return "A Claude profile with that name already exists. Choose another name."
            case .duplicateDirectory: return "That config path uses the same Claude credential store as an existing profile. Choose a different config path."
            case .missingProfile: return "This profile changed or was removed. Refresh the account list and try again."
            case .protectedProfile: return "The default Claude profile and Vertex profiles cannot be renamed or removed here."
            case .unresolvedProfile: return "This wrapper's config folder is unresolved. Import its actual config folder before renaming it."
            case .directoryExists: return "That account folder already exists. Choose a different folder."
            case .invalidDirectory: return "Choose an existing folder with an absolute path. Paths cannot contain line breaks or null characters."
            case .invalidManagedFiles: return "Claudock's profile registry is invalid or was edited externally. Restore it from a backup before making changes."
            case .concurrentChange: return "The profile registry changed while saving. Refresh and try again."
            case .busy: return "Another profile update is in progress. Wait a moment and try again."
            case .unsupportedShellFile: return "The .zshrc file must be a regular file to update shell integration safely."
            case .ioFailure: return "The profile could not be saved. Check that Claudock's data folder is writable."
            }
        }
    }

    public static func add(name: String, configDirectory: String? = nil, home: String = NSHomeDirectory()) throws -> Profile {
        try ProfileStore.add(name: name, configDirectory: configDirectory, home: home)
    }

    public static func rename(profile: Profile, to name: String, home: String = NSHomeDirectory()) throws -> Profile {
        try ProfileStore.rename(profile: profile, to: name, home: home)
    }

    public static func remove(profile: Profile, home: String = NSHomeDirectory()) throws {
        try ProfileStore.remove(profile: profile, home: home)
    }
}
