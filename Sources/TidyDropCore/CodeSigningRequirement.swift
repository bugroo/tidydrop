import Foundation
#if os(macOS)
import Security
#endif

public enum CodeSigningRequirement {
#if os(macOS)
    public static func designatedRequirement(for codeURL: URL) throws -> String {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            codeURL.standardizedFileURL as CFURL,
            [],
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw StewardError.commandFailed("could not load signed code: OSStatus \(createStatus)")
        }

        var requirement: SecRequirement?
        let requirementStatus = SecCodeCopyDesignatedRequirement(staticCode, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            throw StewardError.commandFailed(
                "could not derive designated requirement: OSStatus \(requirementStatus)"
            )
        }

        var requirementText: CFString?
        let textStatus = SecRequirementCopyString(requirement, [], &requirementText)
        guard textStatus == errSecSuccess, let requirementText else {
            throw StewardError.commandFailed(
                "could not serialize designated requirement: OSStatus \(textStatus)"
            )
        }
        let value = requirementText as String
        guard !value.isEmpty, value.utf8.count <= 8_192 else {
            throw StewardError.commandFailed("invalid designated requirement length")
        }
        return value
    }

    public static func currentProcessSatisfies(_ requirementText: String) throws -> Bool {
        guard !requirementText.isEmpty, requirementText.utf8.count <= 8_192 else {
            throw StewardError.invalidConfiguration("invalid code-signing requirement length")
        }
        var requirement: SecRequirement?
        let createStatus = SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        )
        guard createStatus == errSecSuccess, let requirement else {
            throw StewardError.commandFailed(
                "could not parse code-signing requirement: OSStatus \(createStatus)"
            )
        }
        var currentCode: SecCode?
        let selfStatus = SecCodeCopySelf([], &currentCode)
        guard selfStatus == errSecSuccess, let currentCode else {
            throw StewardError.commandFailed("could not inspect current code: OSStatus \(selfStatus)")
        }
        let validationStatus = SecCodeCheckValidity(currentCode, [], requirement)
        if validationStatus == errSecSuccess { return true }
        if validationStatus == errSecCSReqFailed { return false }
        throw StewardError.commandFailed(
            "could not validate code-signing requirement: OSStatus \(validationStatus)"
        )
    }
#else
    public static func designatedRequirement(for codeURL: URL) throws -> String {
        throw StewardError.commandFailed("code-signing requirements are available only on macOS")
    }

    public static func currentProcessSatisfies(_ requirementText: String) throws -> Bool {
        throw StewardError.commandFailed("code-signing requirements are available only on macOS")
    }
#endif
}
