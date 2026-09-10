import Foundation

public enum PabloReadinessState: String, Codable, Sendable {
    case granted, humanActionRequired, awaitingHuman
}

public struct PabloPermissionReadiness: Codable, Sendable {
    public let permission: String
    public let state: PabloReadinessState
    public let humanAction: String?

    public init(permission: String, granted: Bool, humanAction: String) {
        self.permission = permission
        state = granted ? .granted : .humanActionRequired
        self.humanAction = granted ? nil : humanAction
    }
}

public struct PabloCallerReadiness: Codable, Sendable {
    public let state: PabloReadinessState
    public let verified: Bool
    public let humanAction: String?

    public init(state: PabloReadinessState, verified: Bool, humanAction: String?) {
        self.state = state
        self.verified = verified
        self.humanAction = humanAction
    }
}

/// Readiness is advisory. Permissions, target identity, and consent are rechecked at dispatch.
public struct PabloServiceInfo: Codable, Sendable {
    public let serviceID: UUID
    public let version: String
    public let build: String
    public let methods: [String]
    public let permissions: [PabloPermissionReadiness]
    public let approval: PabloCallerReadiness
    public let safariHumanAction: String

    public init(serviceID: UUID, version: String, build: String,
                permissions: [PabloPermissionReadiness], approval: PabloCallerReadiness) {
        self.serviceID = serviceID
        self.version = version
        self.build = build
        methods = PabloControlMethod.allCases.map(\.rawValue).sorted()
        self.permissions = permissions
        self.approval = approval
        safariHumanAction = "Enable Pablo Safari and unlock the intended tab with its toolbar button. Use safari.tabs after approval to inspect current grants."
    }
}
