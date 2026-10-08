// KeychainCredentialVault.swift
// Security-critical: the ONLY plaintext-secret handler in TouchRDP.
// Two-tier auto-detecting vault.
//
// Tier 1 — hardwareBound: data-protection Keychain + SecAccessControl(.biometryCurrentSet).
//   OS cryptographically binds the secret to the Secure Enclave + enrolled biometrics.
//   Available only when signed with a provisioning-profile-backed identity (Apple Development
//   or distribution); unsigned / ad-hoc builds return errSecMissingEntitlement (-34018).
//
// Tier 2 — appGatedFallback: plain legacy Keychain item (no access control, no data-protection),
//   with a mandatory LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics) Touch ID
//   check enforced before releasing secrets (with bounded, per-connection reuse).
//   Works unsigned today.
//   Security delta: weaker than Tier 1 against an attacker with local code-execution as the user
//   (who could bypass the app gate), but defends the primary threat (opportunistic access at an
//   unlocked Mac). Tier 1 closes this gap and is used automatically once the app is signed.
//
// NOTE: Swift String memory cannot be guaranteed-zeroed after use (strings are value types
// managed by ARC; the allocator may retain copies). Tier 1 mitigates this: the secret never
// leaves the Secure Enclave boundary at rest. Tier 2 minimizes plaintext exposure by keeping
// the String's lifetime scoped to the return of retrievePassword.

import Foundation
import Security
import LocalAuthentication

private let kService = "com.touchrdp.app.credential"
private let kErrMissingEntitlement: OSStatus = -34018

public final class KeychainCredentialVault: CredentialVault, @unchecked Sendable {

    // MARK: - Public interface

    public let activeTier: VaultTier
    public var capability: BiometricCapability { makeBiometricCapability() }

    public init() {
        activeTier = Self.detectTier()
    }

    // MARK: - Reuse contexts (credential-reuse policy)
    //
    // Cache only contexts authenticated by this app, bounded by the policy and the
    // platform's maximum reuse window. Device-unlock reuse is always disabled.
    public static let maxReuseSeconds = Int(LATouchIDAuthenticationMaximumAllowableReuseDuration)
    private let authenticationContexts = CredentialAuthenticationContexts()

    // MARK: - Key scheme (F-6)
    //
    // One Keychain service, one account per (connection, kind). The primary account is
    // the bare connection UUID (pre-F-6 items keep working unchanged); the gateway
    // account appends ":gateway". A UUID string is fixed-format (36 hex/hyphen chars),
    // so a gateway account can never collide with any connection's primary account,
    // and distinct UUIDs keep gateway accounts distinct across connections
    // (ValidateCore asserts these properties).
    public static func keychainAccount(for connectionID: UUID, kind: CredentialKind) -> String {
        switch kind {
        case .primary: return connectionID.uuidString
        case .gateway: return connectionID.uuidString + ":gateway"
        }
    }

    private func evictContext(for id: UUID) {
        authenticationContexts.evict(for: id)
    }

    private func evictAllContexts() {
        authenticationContexts.evictAll()
    }

    // MARK: - Tier detection

    private static func detectTier() -> VaultTier {
        // Probe a throwaway Tier-1 write. If it returns -34018 (missing entitlement)
        // or any other failure, fall back to Tier 2. On success, clean up and use Tier 1.
        let probeAccount = "com.touchrdp.tier-probe"
        let probeData = Data([0x00])

        var accessError: Unmanaged<CFError>?
        // Try passcode-set variant first; fall back to when-unlocked if unavailable.
        let accessible: CFTypeRef = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        guard let acl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            accessible,
            [.biometryCurrentSet],
            &accessError
        ) else { return .appGatedFallback }

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: kService,
            kSecAttrAccount: probeAccount,
            kSecValueData: probeData,
            kSecUseDataProtectionKeychain: true,
            kSecAttrAccessControl: acl
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecSuccess {
            // Clean up the probe item.
            let deleteQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: kService,
                kSecAttrAccount: probeAccount,
                kSecUseDataProtectionKeychain: true
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            return .hardwareBound
        } else if status == errSecDuplicateItem {
            // A prior probe survived; still counts as Tier-1 capable.
            let deleteQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: kService,
                kSecAttrAccount: probeAccount,
                kSecUseDataProtectionKeychain: true
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            return .hardwareBound
        } else {
            // -34018 (missing entitlement) or any other failure → Tier 2.
            return .appGatedFallback
        }
    }

    // MARK: - Store

    /// Stores or replaces the password for the given connection. No biometric required.
    public func storePassword(_ password: String, for connectionID: UUID) throws {
        try storePassword(password, for: connectionID, kind: .primary)
    }

    /// F-6: kind-aware store. The gateway secret gets the SAME tier, access policy, and
    /// ThisDeviceOnly protection as the primary — only the account key differs.
    public func storePassword(_ password: String, for connectionID: UUID,
                              kind: CredentialKind) throws {
        // Never persist an empty password: the editor's blank field means "keep the
        // existing one", NLA cannot authenticate with "", and a stored empty item would
        // show as "Saved" while every connect fails with an unrelated-looking error.
        guard !password.isEmpty else { throw VaultError.emptySecret }
        guard let data = password.data(using: .utf8) else {
            throw VaultError.unexpected(errSecParam)
        }

        let account = Self.keychainAccount(for: connectionID, kind: kind)
        // Remove existing items in both tiers so a tier switch can't orphan items.
        try? removeItems(account: account)
        // A credential change invalidates any cached authenticated context: the next
        // retrieval should re-prompt rather than reuse a pre-change Touch ID.
        evictContext(for: connectionID)

        let status: OSStatus
        if activeTier == .hardwareBound {
            status = try addTier1Item(data: data, account: account)
        } else {
            status = addTier2Item(data: data, account: account)
        }

        guard status == errSecSuccess else {
            throw mapStoreError(status)
        }
    }

    // MARK: - Retrieve

    /// Retrieves the password, gated by Touch ID. The plaintext is scoped to this call.
    public func retrievePassword(for connectionID: UUID, reason: String,
                                 allowReuseSeconds: Int?,
                                 forceFreshPrompt: Bool) async throws -> String {
        try await retrieveConnectionSecrets(for: connectionID, includeGateway: false,
                                            reason: reason, allowReuseSeconds: allowReuseSeconds,
                                            forceFreshPrompt: forceFreshPrompt).primary
    }

    /// F-6: release the primary — and, when configured, the gateway — secret under ONE
    /// biometric authentication. The flow's `LAContext` is resolved ONCE (honoring the
    /// policy's reuse window / forceFresh exactly like a single retrieval) and shared by
    /// both Keychain reads, so the gateway read reuses the primary read's Touch ID:
    /// one prompt, two secrets. Only the context is ever cached — never a secret.
    public func retrieveConnectionSecrets(for connectionID: UUID, includeGateway: Bool,
                                          reason: String, allowReuseSeconds: Int?,
                                          forceFreshPrompt: Bool) async throws -> ConnectionSecrets {
        try await withContextEviction(for: connectionID) {
            let request = self.authenticationContexts.begin(
                for: connectionID, reuseSeconds: allowReuseSeconds, forceFresh: forceFreshPrompt)
            let context = request.context
            // Tier 2 enforces the biometric gate once for the whole flow. A cached
            // request is proof of an earlier successful app authentication within
            // this connection's bounded window. Tier 1 always enforces its OS ACL.
            if self.activeTier == .appGatedFallback, request.authenticatedAt == nil {
                try await self.authenticateTier2(context: context, reason: reason)
            }
            let primary = try await self.retrieveSecret(
                account: Self.keychainAccount(for: connectionID, kind: .primary),
                context: context, reason: reason)
            let gateway: String?
            if includeGateway {
                gateway = try await self.retrieveSecret(
                    account: Self.keychainAccount(for: connectionID, kind: .gateway),
                    context: context, reason: reason)
            } else { gateway = nil }
            self.authenticationContexts.complete(request)
            return ConnectionSecrets(primary: primary, gateway: gateway)
        }
    }

    /// LIFE-6 wrapper: evict the cached LAContext when a failure means it is unusable, so
    /// the next attempt re-prompts with a fresh context. Preserve reuse on a plain
    /// user-cancel (the context is still valid; the user simply dismissed the prompt).
    private func withContextEviction<T>(for connectionID: UUID,
                                        _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let e as VaultError {
            switch e {
            case .invalidated, .authenticationFailed, .biometricUnavailable:
                evictContext(for: connectionID)
            default:
                break
            }
            throw e
        }
    }

    /// One Keychain read on the active tier with an EXPLICIT context (shared across the
    /// reads of a flow — see retrieveConnectionSecrets).
    private func retrieveSecret(account: String, context: LAContext,
                                reason: String) async throws -> String {
        if activeTier == .hardwareBound {
            return try await retrieveTier1(account: account, context: context, reason: reason)
        } else {
            return try retrieveTier2(account: account)
        }
    }

    // MARK: - Has / Delete

    /// Returns true if a password exists without triggering a biometric prompt.
    public func hasPassword(for connectionID: UUID) -> Bool {
        hasPassword(for: connectionID, kind: .primary)
    }

    public func hasPassword(for connectionID: UUID, kind: CredentialKind) -> Bool {
        // Attributes-only query with kSecUseAuthenticationUISkip so we never prompt.
        // errSecInteractionNotAllowed means item exists but is biometric-locked → treat as present.
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: kService,
            kSecAttrAccount: Self.keychainAccount(for: connectionID, kind: kind),
            kSecReturnAttributes: true,
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess || status == errSecInteractionNotAllowed { return true }

        // Also probe the data-protection tier.
        var dpQuery = query
        dpQuery[kSecUseDataProtectionKeychain] = true
        let dpStatus = SecItemCopyMatching(dpQuery as CFDictionary, nil)
        return dpStatus == errSecSuccess || dpStatus == errSecInteractionNotAllowed
    }

    /// Deletes ALL of a connection's secrets (every kind) from both keychain tiers —
    /// the delete-on-connection-delete path can never orphan a gateway item (F-6).
    public func deletePassword(for connectionID: UUID) throws {
        evictContext(for: connectionID)
        for kind in CredentialKind.allCases {
            try removeItems(account: Self.keychainAccount(for: connectionID, kind: kind))
        }
    }

    /// Deletes one kind's secret only (e.g. the gateway secret when the editor's
    /// "separate gateway credentials" toggle is switched off).
    public func deletePassword(for connectionID: UUID, kind: CredentialKind) throws {
        evictContext(for: connectionID)
        try removeItems(account: Self.keychainAccount(for: connectionID, kind: kind))
    }

    /// Deletes all passwords stored by this vault, across both tiers.
    public func deleteAll() throws {
        evictAllContexts()
        let legacyQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: kService
        ]
        let s1 = SecItemDelete(legacyQuery as CFDictionary)
        if s1 != errSecSuccess && s1 != errSecItemNotFound {
            throw VaultError.unexpected(s1)
        }

        let dpQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: kService,
            kSecUseDataProtectionKeychain: true
        ]
        let s2 = SecItemDelete(dpQuery as CFDictionary)
        if s2 != errSecSuccess && s2 != errSecItemNotFound {
            throw VaultError.unexpected(s2)
        }
    }

    // MARK: - Tier 1 helpers

    private func addTier1Item(data: Data, account: String) throws -> OSStatus {
        var accessError: Unmanaged<CFError>?

        // Prefer passcode-set variant; fall back if the device has no passcode configured.
        var accessible: CFTypeRef = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        guard var acl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault, accessible, [.biometryCurrentSet], &accessError
        ) else { throw VaultError.unexpected(errSecParam) }

        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: kService,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecUseDataProtectionKeychain: true,
            kSecAttrAccessControl: acl
        ]

        var status = SecItemAdd(query as CFDictionary, nil)

        // If passcode-set variant was rejected (no passcode on device), try when-unlocked.
        if status != errSecSuccess && status != errSecDuplicateItem {
            accessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            if let fallbackAcl = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault, accessible, [.biometryCurrentSet], &accessError
            ) {
                acl = fallbackAcl
                query[kSecAttrAccessControl] = acl
                status = SecItemAdd(query as CFDictionary, nil)
            }
        }

        return status
    }

    private func retrieveTier1(account: String, context: LAContext,
                               reason: String) async throws -> String {
        // Run the (blocking) biometric keychain read OFF the main thread — the
        // caller may be main-actor-isolated, and SecItemCopyMatching blocks the
        // calling thread while the Touch ID prompt is up.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                context.localizedReason = reason

                let query: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: kService,
                    kSecAttrAccount: account,
                    kSecReturnData: true,
                    kSecUseDataProtectionKeychain: true,
                    kSecUseAuthenticationContext: context
                ]

                var result: AnyObject?
                let status = autoreleasepool {
                    SecItemCopyMatching(query as CFDictionary, &result)
                }

                // Distinguish a biometric-set invalidation (PRD §9.4) from a missing
                // item: if the item is still physically present but the read failed,
                // the enrolled-biometrics changed and the secret must be re-stored.
                if status == errSecAuthFailed || status == errSecItemNotFound,
                   self.itemPhysicallyExistsTier1(account: account) {
                    continuation.resume(throwing: VaultError.invalidated)
                    return
                }

                continuation.resume(with: self.mapRetrieveResult(status: status, result: result))
            }
        }
    }

    /// Attributes-only presence check (no prompt) for the data-protection item.
    private func itemPhysicallyExistsTier1(account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: kService,
            kSecAttrAccount: account,
            kSecReturnAttributes: true,
            kSecUseDataProtectionKeychain: true,
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    // MARK: - Tier 2 helpers

    private func addTier2Item(data: Data, account: String) -> OSStatus {
        // Plain legacy item — no access control, no data-protection flag.
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: kService,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }

    private func authenticateTier2(context: LAContext, reason: String) async throws {
        let success: Bool
        do {
            success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch let error as LAError {
            throw mapLAError(error)
        } catch {
            throw VaultError.unexpected(errSecAuthFailed)
        }
        guard success else { throw VaultError.authenticationFailed }
    }

    /// Called only inside retrieveConnectionSecrets, after its biometric gate.
    private func retrieveTier2(account: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: kService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip
        ]

        var result: AnyObject?
        let status = autoreleasepool {
            SecItemCopyMatching(query as CFDictionary, &result)
        }

        // Biometric passed, so any read failure while the item is physically present
        // means the item itself is unreadable by THIS app identity — e.g. it was
        // stored by a differently-signed (ad-hoc re-signed) build and its keychain
        // ACL no longer trusts us. Surface as `invalidated` (re-store needed) rather
        // than leaking a raw OSStatus.
        if status != errSecSuccess, itemPhysicallyExistsTier2(account: account) {
            throw VaultError.invalidated
        }

        return try mapRetrieveResult(status: status, result: result).get()
    }

    /// Attributes-only presence check (no prompt, no secret access) for the legacy item.
    /// Metadata stays readable even when the item's ACL blocks us from the secret data.
    private func itemPhysicallyExistsTier2(account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: kService,
            kSecAttrAccount: account,
            kSecReturnAttributes: true,
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    // MARK: - Shared deletion

    /// Removes the item for one account from both the legacy and data-protection keychains.
    private func removeItems(account: String) throws {
        let legacyQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: kService,
            kSecAttrAccount: account
        ]
        let s1 = SecItemDelete(legacyQuery as CFDictionary)
        if s1 != errSecSuccess && s1 != errSecItemNotFound {
            throw VaultError.unexpected(s1)
        }

        let dpQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: kService,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true
        ]
        let s2 = SecItemDelete(dpQuery as CFDictionary)
        if s2 != errSecSuccess && s2 != errSecItemNotFound {
            throw VaultError.unexpected(s2)
        }
    }

    // MARK: - Capability

    private func makeBiometricCapability() -> BiometricCapability {
        let ctx = LAContext()
        var error: NSError?
        let biometricAvailable = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                       error: &error)
        let kind: BiometryKind
        if biometricAvailable {
            switch ctx.biometryType {
            case .touchID: kind = .touchID
            case .faceID:  kind = .faceID
            default:       kind = .none
            }
        } else {
            kind = .none
        }

        var deviceError: NSError?
        let deviceOwnerAvailable = ctx.canEvaluatePolicy(.deviceOwnerAuthentication,
                                                         error: &deviceError)

        return BiometricCapability(
            available: biometricAvailable,
            type: kind,
            deviceOwnerAuthAvailable: deviceOwnerAvailable
        )
    }

    // MARK: - Error mapping

    private func mapStoreError(_ status: OSStatus) -> VaultError {
        switch status {
        case errSecDuplicateItem: return .duplicate
        case kErrMissingEntitlement: return .unexpected(status)
        default: return .unexpected(status)
        }
    }

    private func mapRetrieveResult(status: OSStatus,
                                   result: AnyObject?) -> Result<String, VaultError> {
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                return .failure(.unexpected(errSecDecode))
            }
            // An item with no bytes (stored by a build that allowed it) is not a usable
            // credential — report it as such rather than handing "" to the session.
            guard !password.isEmpty else { return .failure(.emptySecret) }
            return .success(password)
        case errSecItemNotFound:
            return .failure(.itemNotFound)
        case errSecUserCanceled:
            return .failure(.userCancelled)
        case errSecAuthFailed:
            // Could be biometric set changed (invalidated) or plain auth failure.
            // We surface as authenticationFailed; callers can check `hasPassword` to
            // distinguish a missing item (invalidated) from a failed auth.
            return .failure(.authenticationFailed)
        default:
            return .failure(.unexpected(status))
        }
    }

    private func mapLAError(_ error: LAError) -> VaultError {
        switch error.code {
        case .userCancel, .appCancel, .systemCancel:
            return .userCancelled
        case .authenticationFailed:
            return .authenticationFailed
        case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout:
            return .biometricUnavailable
        case .invalidContext:
            return .unexpected(errSecBadReq)
        default:
            return .unexpected(OSStatus(error.code.rawValue))
        }
    }
}
