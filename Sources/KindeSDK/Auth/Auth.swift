import AppAuth
import os.log

// MARK: - Pagination Models

/// Pagination metadata for API responses
public struct EntitlementsMetadata: Codable {
    /// Whether there are more pages available
    public let hasMore: Bool
    /// Token to get the next page of results
    public let nextPageStartingAfter: String?
    
    private enum CodingKeys: String, CodingKey {
        case hasMore = "has_more"
        case nextPageStartingAfter = "next_page_starting_after"
    }
}

/// Individual entitlement model
public struct Entitlement: Codable {
    /// The entitlement key/name
    public let key: String
    /// The entitlement value
    public let value: AnyCodable
    /// The entitlement type
    public let type: String?
    
    private enum CodingKeys: String, CodingKey {
        case key, value, type
    }
}

/// Entitlement plan model
public struct EntitlementPlan: Codable {
    /// The plan code
    public let code: String
    /// The plan name
    public let name: String?
    /// The plan description
    public let description: String?
}

/// Entitlements data container
public struct Entitlements: Codable {
    /// Organization code
    public let orgCode: String
    /// List of entitlement plans
    public let plans: [EntitlementPlan]
    /// List of entitlements
    public let entitlements: [Entitlement]
    
    private enum CodingKeys: String, CodingKey {
        case orgCode = "org_code"
        case plans, entitlements
    }
}

/// Entitlements API response with pagination
public struct EntitlementsResponse: Codable {
    /// The entitlements data
    public let data: Entitlements
    /// Pagination metadata
    public let metadata: EntitlementsMetadata
}

/// Single entitlement response
public struct EntitlementResponse: Codable {
    /// The entitlement data
    public let data: Entitlement
}

/// The Kinde authentication service
public final class Auth {
    @Atomic private var currentAuthorizationFlow: OIDExternalUserAgentSession?
    
    private let config: Config
    private let authStateRepository: AuthStateRepository
    private let logger: LoggerProtocol
    private var privateAuthSession: Bool = false
    
    // MARK: - Service Properties
    
    /// Claims service for accessing user claims from tokens
    public lazy var claims: ClaimsService = ClaimsService(auth: self, logger: logger)
    
    /// Entitlements service for managing user entitlements
    public lazy var entitlements: EntitlementsService = EntitlementsService(auth: self, logger: logger)
    
    /// Feature flags service for managing feature flags
    public lazy var featureFlags: FeatureFlagsService = FeatureFlagsService(auth: self, logger: logger)
    
    init(config: Config, authStateRepository: AuthStateRepository, logger: LoggerProtocol) {
        self.config = config
        self.authStateRepository = authStateRepository
        self.logger = logger
    }
    
    /// Is the user authenticated as of the last use of authentication state?
    public func isAuthorized() -> Bool {
        return authStateRepository.state?.isAuthorized ?? false
    }
    
    public func isAuthenticated() -> Bool {
        let isAuthorized = authStateRepository.state?.isAuthorized
        guard let lastTokenResponse = authStateRepository.state?.lastTokenResponse else {
            return false
        }
        guard let accessTokenExpirationDate = lastTokenResponse.accessTokenExpirationDate else {
            return false
        }
        return lastTokenResponse.accessToken != nil &&
               isAuthorized == true &&
               accessTokenExpirationDate > Date()
    }
    
    public func getUserDetails() -> User? {
        guard let params = authStateRepository.state?.lastTokenResponse?.idToken?.parsedJWT else {
            return nil
        }
        if let idValue = params["sub"] as? String,
           let email = params["email"] as? String {
            let givenName = params["given_name"] as? String
            let familyName = params["family_name"] as? String
            let picture = params["picture"] as? String
            return User(id: idValue,
                        email: email,
                        lastName: familyName,
                        firstName: givenName,
                        picture: picture)
        }
        return nil
    }
    

    public func getClaim(forKey key: String, token: TokenType = .accessToken) -> Claim? {
        let lastTokenResponse = authStateRepository.state?.lastTokenResponse
        let tokenToParse = token == .accessToken ? lastTokenResponse?.accessToken: lastTokenResponse?.idToken
        guard let params = tokenToParse?.parsedJWT else {
            return nil
        }
        if let valueOrNil = params[key],
            let value = valueOrNil {
            return Claim(name: key, value: AnyCodable(value))
        }
        return nil
    }
    
    @available(*, deprecated, message: "Use getClaim(forKey:token:) with return type Claim?")
    public func getClaim(key: String, token: TokenType = .accessToken) -> Any? {
        let lastTokenResponse = authStateRepository.state?.lastTokenResponse
        let tokenToParse = token == .accessToken ? lastTokenResponse?.accessToken: lastTokenResponse?.idToken
        guard let params = tokenToParse?.parsedJWT else {
            return nil
        }
        if !params.keys.contains(key) {
            os_log("The claimed value of \"%@\" does not exist in your token", log: .default, type: .error, key)
        }
        return params[key] ?? nil
    }
    
    public func getPermissions() -> Permissions? {
        if let permissionsClaim = getClaim(forKey: ClaimKey.permissions.rawValue),
           let permissionsArray = permissionsClaim.value as? [String],
           let orgCodeClaim = getClaim(forKey: ClaimKey.organisationCode.rawValue),
           let orgCode = orgCodeClaim.value as? String {
            
            let organization = Organization(code: orgCode)
            let permissions = Permissions(organization: organization,
                                          permissions: permissionsArray)
            return permissions
        }
        return nil
    }
    
    public func getPermission(name: String) -> Permission? {
        if let permissionsClaim = getClaim(forKey: ClaimKey.permissions.rawValue),
           let permissionsArray = permissionsClaim.value as? [String],
           let orgCodeClaim = getClaim(forKey: ClaimKey.organisationCode.rawValue),
           let orgCode = orgCodeClaim.value as? String {
            
            let organization = Organization(code: orgCode)
            let permission = Permission(organization: organization,
                                        isGranted: permissionsArray.contains(name))
            return permission
        }
        return nil
    }
    
    public func getOrganization() -> Organization? {
        if let orgCodeClaim = getClaim(forKey: ClaimKey.organisationCode.rawValue),
           let orgCode = orgCodeClaim.value as? String {
            let org = Organization(code: orgCode)
            return org
        }
        return nil
    }
    
    public func getUserOrganizations() -> UserOrganizations? {
        if let userOrgsClaim = getClaim(forKey: ClaimKey.organisationCodes.rawValue,
                                   token: .idToken),
           let userOrgs = userOrgsClaim.value as? [String] {
            
            let orgCodes = userOrgs.map({ Organization(code: $0)})
            return UserOrganizations(orgCodes: orgCodes)
        }
        return nil
    }
    
    private func getViewController() async -> UIViewController? {
        await MainActor.run {
            let keyWindow = UIApplication.shared.connectedScenes.flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
                                                                .first { $0.isKeyWindow }
            var topController = keyWindow?.rootViewController
            while let presentedViewController = topController?.presentedViewController {
                topController = presentedViewController
            }
            return topController
        }
    }
    
    /// Register a new user
    ///
    @available(*, renamed: "register")
    public func register(orgCode: String = "", loginHint: String = "", planInterest: String = "", pricingTableKey: String = "",
                         _ completion: @escaping (Result<Bool, Error>) -> Void) {
        Task {
            do {
                try await register(orgCode: orgCode, loginHint: loginHint, planInterest: planInterest, pricingTableKey: pricingTableKey)
                await MainActor.run(body: {
                    completion(.success(true))
                })
            } catch {
                await MainActor.run(body: {
                    completion(.failure(error))
                })
            }
        }
    }
    
    public func register(orgCode: String = "", loginHint: String = "", planInterest: String = "", pricingTableKey: String = "") async throws -> () {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                guard let viewController = await self.getViewController() else {
                    continuation.resume(throwing: AuthError.notAuthenticated)
                    return
                }
                do {
                    let request = try await self.getAuthorizationRequest(signUp: true, orgCode: orgCode, loginHint: loginHint, planInterest: planInterest, pricingTableKey: pricingTableKey)
                    _ = try await self.runCurrentAuthorizationFlow(request: request, viewController: viewController)
                    continuation.resume(with: .success(()))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Login an existing user
    ///
    @available(*, renamed: "login")
    public func login(orgCode: String = "", loginHint: String = "",
                      _ completion: @escaping (Result<Bool, Error>) -> Void) {
        Task {
            do {
                try await login(orgCode: orgCode, loginHint: loginHint)
                await MainActor.run(body: {
                    completion(.success(true))
                })
            } catch {
                await MainActor.run(body: {
                    completion(.failure(error))
                })
            }
        }
    }

    public func login(orgCode: String = "", loginHint: String = "") async throws -> () {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                guard let viewController = await self.getViewController() else {
                    continuation.resume(throwing: AuthError.notAuthenticated)
                    return
                }
                do {
                    let request = try await self.getAuthorizationRequest(signUp: false, orgCode: orgCode, loginHint: loginHint)
                    _ = try await self.runCurrentAuthorizationFlow(request: request, viewController: viewController)
                    continuation.resume(with: .success(()))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
        
    /// Register a new organization
    ///
    @available(*, renamed: "createOrg")
    public func createOrg( _ completion: @escaping (Result<Bool, Error>) -> Void) {
        Task {
            do {
                try await createOrg()
                await MainActor.run(body: {
                    completion(.success(true))
                })
            } catch {
                await MainActor.run(body: {
                    completion(.failure(error))
                })
            }
        }
    }

    public func createOrg(orgName: String = "") async throws -> () {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                guard let viewController = await self.getViewController() else {
                    continuation.resume(throwing: AuthError.notAuthenticated)
                    return
                }
                do {
                    let request = try await self.getAuthorizationRequest(signUp: true, createOrg: true, orgName: orgName)
                    _ = try await self.runCurrentAuthorizationFlow(request: request, viewController: viewController)
                    continuation.resume(with: .success(()))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Logout the current user
    @available(*, renamed: "logout()")
    public func logout(_ completion: @escaping (_ result: Bool) -> Void) {
        Task {
            let result = await logout()
            await MainActor.run {
                completion(result)
            }
        }
    }
    
    public func logout() async -> Bool {
        // There is no logout endpoint configured; simply clear the local auth state
        let cleared = authStateRepository.clear()
        return cleared
    }
    
    /// Create an Authorization Request using the configured Issuer and Redirect URLs,
    /// and OpenIDConnect configuration discovery
    @available(*, renamed: "getAuthorizationRequest(signUp:createOrg:orgCode:usePKCE:useNonce:)")
    private func getAuthorizationRequest(signUp: Bool,
                                         createOrg: Bool = false,
                                         orgCode: String = "",
                                         usePKCE: Bool = true,
                                         useNonce: Bool = false,
                                         then completion: @escaping (Result<OIDAuthorizationRequest, Error>) -> Void) {
        Task {
            do {
                let request = try await self.getAuthorizationRequest(signUp: signUp, createOrg: createOrg, orgCode: orgCode, usePKCE: usePKCE, useNonce: useNonce)
                completion(.success(request))
            } catch {
                completion(.failure(AuthError.notAuthenticated))
            }
        }
    }
    
    private func getAuthorizationRequest(signUp: Bool,
                                         createOrg: Bool = false,
                                         orgCode: String = "",
                                         loginHint: String = "",
                                         orgName: String = "",
                                         usePKCE: Bool = true,
                                         useNonce: Bool = false,
                                         planInterest: String = "",
                                         pricingTableKey: String = "") async throws -> OIDAuthorizationRequest {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                let issuerUrl = config.getIssuerUrl()
                guard let issuerUrl = issuerUrl else {
                    logger.error(message: "Failed to get issuer URL")
                    continuation.resume(throwing: AuthError.configuration)
                    return
                }
                do {
                    let result = try await discoverConfiguration(issuerUrl: issuerUrl,
                                                                 signUp: signUp,
                                                                 createOrg: createOrg,
                                                                 orgCode: orgCode,
                                                                 loginHint: loginHint,
                                                                 orgName: orgName,
                                                                 usePKCE: usePKCE,
                                                                 useNonce: useNonce,
                                                                 planInterest: planInterest,
                                                                 pricingTableKey: pricingTableKey)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func runCurrentAuthorizationFlow(request: OIDAuthorizationRequest, viewController: UIViewController) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await MainActor.run {
                    currentAuthorizationFlow = OIDAuthState.authState(byPresenting: request,
                                                                      presenting: viewController,
                                                                      prefersEphemeralSession: privateAuthSession,
                                                                      callback: authorizationFlowCallback(then: { value in
                        switch value {
                        case .success:
                            continuation.resume(returning: true)
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }))
                }
            }
        }
    }
    
    private func discoverConfiguration(issuerUrl: URL,
                                              signUp: Bool,
                                              createOrg: Bool = false,
                                              orgCode: String = "",
                                              loginHint: String = "",
                                              orgName: String = "",
                                              usePKCE: Bool = true,
                                              useNonce: Bool = false,
                                              planInterest: String = "",
                                              pricingTableKey: String = "") async throws -> (OIDAuthorizationRequest) {
        return try await withCheckedThrowingContinuation { continuation in
            OIDAuthorizationService.discoverConfiguration(forIssuer: issuerUrl) { configuration, error in
                if let error = error {
                    self.logger.error(message: "Failed to discover OpenID configuration: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let configuration = configuration else {
                    self.logger.error(message: "Failed to discover OpenID configuration")
                    continuation.resume(throwing: AuthError.configuration)
                    return
                }
                
                let redirectUrl = self.config.getRedirectUrl()
                guard let redirectUrl = redirectUrl else {
                    self.logger.error(message: "Failed to get redirect URL")
                    continuation.resume(throwing: AuthError.configuration)
                    return
                }
                
                var additionalParameters = [
                    "start_page": signUp ? "registration" : "login",
                    // Force fresh login
                    "prompt": "login"
                ]
                
                if createOrg {
                    additionalParameters["is_create_org"] = "true"
                }
                
                if let audience = self.config.audience, !audience.isEmpty {
                   additionalParameters["audience"] = audience
                }
                
                if !orgCode.isEmpty {
                    additionalParameters["org_code"] = orgCode
                }
                
                if !orgName.isEmpty {
                    additionalParameters["org_name"] = orgName
                }

                if !loginHint.isEmpty {
                    additionalParameters["login_hint"] = loginHint
                }
                
                if !planInterest.isEmpty {
                    additionalParameters["plan_interest"] = planInterest
                }

                if !pricingTableKey.isEmpty {
                    additionalParameters["pricing_table_key"] = pricingTableKey
                }

                // if/when the API supports nonce validation
                let codeChallengeMethod = usePKCE ? OIDOAuthorizationRequestCodeChallengeMethodS256 : nil
                let codeVerifier = usePKCE ? OIDTokenUtilities.randomURLSafeString(withSize: 32) : nil
                let codeChallenge = usePKCE && codeVerifier != nil ? OIDTokenUtilities.encodeBase64urlNoPadding(OIDTokenUtilities.sha256(codeVerifier!)) : nil
                let state = OIDTokenUtilities.randomURLSafeString(withSize: 32)
                let nonce = useNonce ? OIDTokenUtilities.randomURLSafeString(withSize: 32) : nil

                let request = OIDAuthorizationRequest(configuration: configuration,
                                                      clientId: self.config.clientId,
                                                      clientSecret: nil, // Only required for Client Credentials Flow
                                                      scope: self.config.scope,
                                                      redirectURL: redirectUrl,
                                                      responseType: OIDResponseTypeCode,
                                                      state: state,
                                                      nonce: nonce,
                                                      codeVerifier: codeVerifier,
                                                      codeChallenge: codeChallenge,
                                                      codeChallengeMethod: codeChallengeMethod,
                                                      additionalParameters: additionalParameters)
                
                continuation.resume(returning: request)
            }
        }
    }
    
    func extractEmail(from idToken: String) -> String? {
        let params = idToken.parsedJWT
        return params["email"] as? String
    }
    
    func hasMatchingEmail(in authState: OIDAuthState) -> Bool {
        guard let currentIDToken = authState.lastTokenResponse?.idToken,
              let existingIDToken = self.authStateRepository.state?.lastTokenResponse?.idToken,
              let currentEmail = extractEmail(from: currentIDToken),
              let existingEmail = extractEmail(from: existingIDToken)
        else { return false }
        return currentEmail == existingEmail
    }

    /// Callback to complete the current authorization flow
    private func authorizationFlowCallback(then completion: @escaping (Result<Bool, Error>) -> Void) -> (OIDAuthState?, Error?) -> Void {
        return { authState, error in
            if let error = error {
                self.logger.error(message: "Failed to finish authentication flow: \(error.localizedDescription)")
                _ = self.authStateRepository.clear()
                return completion(.failure(error))
            }
            
            guard let authState = authState else {
                self.logger.error(message: "Failed to get authentication state")
                _ = self.authStateRepository.clear()
                return completion(.failure(AuthError.notAuthenticated))
            }
            
            let shouldPreserveState = self.isAuthenticated() && self.hasMatchingEmail(in: authState)
            let saved = shouldPreserveState ? true : self.authStateRepository.setState(authState)
            
            if !saved {
                return completion(.failure(AuthError.failedToSaveState))
            }
            
            self.currentAuthorizationFlow = nil
            completion(.success(true))
        }
    }
    
    /// Is the given error the result of user cancellation of an authorization flow
    public func isUserCancellationErrorCode(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == OIDGeneralErrorDomain && error.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue
    }
    
    /// Perform an action, such as an API call, with a valid access token and ID token
    /// Failure to get a valid access token may require reauthentication
    @available(*, renamed: "performWithFreshTokens()")
    func performWithFreshTokens(_ action: @escaping (Result<Tokens, Error>) -> Void) {
        Task {
            do {
                if let result = try await performWithFreshTokens() {
                    action(.success(result))
                } else {
                    action(.failure(AuthError.notAuthenticated))
                }
            } catch {
                action(.failure(error))
            }
        }
    }

    func performWithFreshTokens() async throws -> Tokens? {
        guard let authState = authStateRepository.state else {
            self.logger.error(message: "Failed to get authentication state")
            return nil
        }
        
        let params = ["Kinde-SDK": "Swift/\(SDKVersion.versionString)"]
        return try await withCheckedThrowingContinuation { continuation in
            authState.performAction(freshTokens: { (accessToken, idToken, error1) in
                if let error = error1 {
                    self.logger.error(message: "Failed to get authentication tokens: \(error.localizedDescription)")
                    return continuation.resume(with: .failure(error))
                }
                
                guard let accessToken1 = accessToken else {
                    self.logger.error(message: "Failed to get access token")
                    return continuation.resume(with: .failure(AuthError.notAuthenticated))
                }
                let tokens = Tokens(accessToken: accessToken1, idToken: idToken)
                continuation.resume(with: .success(tokens))
            }, additionalRefreshParameters: params)
        }
    }
    
    /// Return the desired token with auto-refresh mechanism.
    /// - Returns: Returns either the access token (default) or the id token, throw error if failed to refresh which may require re-authentication.
    public func getToken(desiredToken: TokenType = .accessToken) async throws -> String {
        do {
            if let tokens = try await performWithFreshTokens() {
                if let token = (desiredToken == .accessToken ? tokens.accessToken : tokens.idToken) {
                    return token
                } else {
                    throw AuthError.notAuthenticated
                }
            } else {
                throw AuthError.notAuthenticated
            }
        } catch {
            throw AuthError.notAuthenticated
        }
    }
    
    public func getToken() async throws -> Tokens {
        do {
            if let tokens = try await performWithFreshTokens() {
                return Tokens(accessToken: tokens.accessToken, idToken: tokens.idToken)
            } else {
                throw AuthError.notAuthenticated
            }
        } catch {
            throw AuthError.notAuthenticated
        }
    }
}

// MARK: - Feature Flags
extension Auth {
    
    public func getFlag(code: String, defaultValue: Any? = nil, flagType: Flag.ValueType? = nil) throws -> Flag {
        return try getFlagInternal(code: code, defaultValue: defaultValue, flagType: flagType)
    }
    
    // Wrapper Methods
    
    public func getBooleanFlag(code: String, defaultValue: Bool? = nil) throws -> Bool {
        if let value = try getFlag(code: code, defaultValue: defaultValue, flagType: .bool).value as? Bool {
            return value
        }else {
            if let defaultValue = defaultValue {
                return defaultValue
            }else {
                throw FlagError.notFound
            }
        }
    }
    
    public func getStringFlag(code: String, defaultValue: String? = nil) throws -> String {
        if let value = try getFlag(code: code, defaultValue: defaultValue, flagType: .string).value as? String {
           return value
        }else{
            if let defaultValue = defaultValue {
                return defaultValue
            }else {
                throw FlagError.notFound
            }
        }
    }
    
    public func getIntegerFlag(code: String, defaultValue: Int? = nil) throws -> Int {
        if let value = try getFlag(code: code, defaultValue: defaultValue, flagType: .int).value as? Int {
            return value
        }else {
            if let defaultValue = defaultValue {
                return defaultValue
            }else {
                throw FlagError.notFound
            }
        }
    }
    
    // Internal
    
    private func getFlagInternal(code: String, defaultValue: Any?, flagType: Flag.ValueType?) throws -> Flag {
        
        guard let featureFlagsClaim = getClaim(forKey: ClaimKey.featureFlags.rawValue) else {
            throw FlagError.unknownError
        }
        
        guard let featureFlags = featureFlagsClaim.value as? [String : Any] else {
            throw FlagError.unknownError
        }
        
        if let flagData = featureFlags[code] as? [String: Any],
           let valueTypeLetter = flagData["t"] as? String,
           let actualFlagType = Flag.ValueType(rawValue: valueTypeLetter),
           let actualValue = flagData["v"] {
            
            // Value type check
            if let flagType = flagType,
                flagType != actualFlagType {
                throw FlagError.incorrectType("Flag \"\(code)\" is type \(actualFlagType.typeDescription) - requested type \(flagType.typeDescription)")
            }
            
            return Flag(code: code, type: actualFlagType, value: actualValue)
            
        }else {
            
            if let defaultValue = defaultValue {
                // This flag does not exist - default value provided
                return Flag(code: code, type: nil, value: defaultValue, isDefault: true)
            }else {
                throw FlagError.notFound
            }
        }
    }
}


extension Auth {
    /// Hide/Show message prompt in authentication sessions.
    public func enablePrivateAuthSession(_ isEnable: Bool) {
        privateAuthSession = isEnable
    }
    
    /// Get the current token response
    /// - Returns: The current token response if available
    public func getTokenResponse() -> OIDTokenResponse? {
        return authStateRepository.state?.lastTokenResponse
    }
}

// MARK: - Temporary Inline Types (to be moved to separate files later)

/// Helper type for encoding/decoding Any values in JSON
public struct AnyCodable: Codable {
    public let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            value = NSNull()
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let arrayValue = try? container.decode([AnyCodable].self) {
            value = arrayValue.map { $0.value }
        } else if let dictionaryValue = try? container.decode([String: AnyCodable].self) {
            value = dictionaryValue.mapValues { $0.value }
        } else {
            throw DecodingError.typeMismatch(AnyCodable.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let stringValue as String:
            try container.encode(stringValue)
        case let intValue as Int:
            try container.encode(intValue)
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let arrayValue as [Any]:
            let anyCodableArray = arrayValue.map { AnyCodable($0) }
            try container.encode(anyCodableArray)
        case let dictionaryValue as [String: Any]:
            let anyCodableDictionary = dictionaryValue.mapValues { AnyCodable($0) }
            try container.encode(anyCodableDictionary)
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
}

/// Represents a feature flag with its code, type, and value
public struct Flag {
    public let code: String
    public let type: ValueType?
    public let value: Any
    public let isDefault: Bool

    public init(code: String, type: ValueType?, value: Any, isDefault: Bool = false) {
        self.code = code
        self.type = type
        self.value = value
        self.isDefault = isDefault
    }
    
    public enum ValueType: String {
        case string = "s"
        case int = "i"
        case bool = "b"
        
        fileprivate var typeDescription: String {
            switch self {
            case .string: return "string"
            case .bool: return "boolean"
            case .int: return "integer"
            }
        }
    }
}

/// Represents a JWT claim with its name and value
public struct Claim: Codable {
    /// The name/key of the claim
    public let name: String
    
    /// The value of the claim (can be any type)
    public let value: AnyCodable
    
    public init(name: String, value: AnyCodable) {
        self.name = name
        self.value = value
    }
}

/// Represents a feature flag with its value and metadata
public struct FeatureFlag: Codable {
    /// The feature flag code/identifier
    public let code: String
    
    /// The type of the feature flag value
    public let type: ValueType?
    
    /// The actual value of the feature flag
    public let value: AnyCodable
    
    /// Whether this is a default value
    public let isDefault: Bool
    
    public init(code: String, type: ValueType?, value: AnyCodable, isDefault: Bool = false) {
        self.code = code
        self.type = type
        self.value = value
        self.isDefault = isDefault
    }
    
    /// Enum representing the type of feature flag value
    public enum ValueType: String, Codable {
        case string = "s"
        case int = "i"
        case bool = "b"
        
        public var typeDescription: String {
            switch self {
            case .string: return "string"
            case .bool: return "boolean"
            case .int: return "integer"
            }
        }
    }
}

/// Represents an organization
public struct Organization: Codable {
    /// The organization code
    public let code: String
    
    public init(code: String) {
        self.code = code
    }
}

/// Represents a permission with organization context
public struct Permission: Codable {
    /// The organization this permission belongs to
    public let organization: Organization
    
    /// Whether the permission is granted
    public let isGranted: Bool
    
    public init(organization: Organization, isGranted: Bool) {
        self.organization = organization
        self.isGranted = isGranted
    }
}

/// Collection of permissions
public struct Permissions: Codable {
    /// The organization these permissions belong to
    public let organization: Organization
    
    /// List of permission names
    public let permissions: [String]
    
    public init(organization: Organization, permissions: [String]) {
        self.organization = organization
        self.permissions = permissions
    }
}

/// Collection of user organizations
public struct UserOrganizations: Codable {
    /// List of organization codes
    public let orgCodes: [Organization]
    
    public init(orgCodes: [Organization]) {
        self.orgCodes = orgCodes
    }
}

/// Service for managing JWT claims with type-safe API
public class ClaimsService {
    private unowned let auth: Auth
    private let logger: LoggerProtocol
    
    public init(auth: Auth, logger: LoggerProtocol = DefaultLogger()) {
        self.auth = auth
        self.logger = logger
    }
    
    /// Get a specific claim by key
    /// - Parameter key: The claim key to retrieve
    /// - Returns: Claim if found, nil otherwise
    public func getClaim(forKey key: String) -> Claim? {
        return auth.getClaim(forKey: key)
    }
    
    /// Check if a specific permission is granted
    /// - Parameter name: The permission name to check
    /// - Returns: True if permission is granted, false otherwise
    public func getPermission(name: String) -> Bool {
        return auth.getPermission(name: name) != nil
    }
}

/// Service for managing user entitlements with type-safe API
public class EntitlementsService {
    private unowned let auth: Auth
    private let logger: LoggerProtocol
    
    public init(auth: Auth, logger: LoggerProtocol = DefaultLogger()) {
        self.auth = auth
        self.logger = logger
    }
    
    /// Get all entitlements for the current user
    /// - Returns: Dictionary of entitlements with their values, or empty dictionary if not available
    public func getEntitlements() -> [String: Any] {
        guard let claim = auth.claims.getClaim(forKey: "entitlements") else {
            return [:]
        }
        
        let rawValue = claim.value.value
        
        // Try to parse as JSON string first
        if let claimString = rawValue as? String,
           let data = claimString.data(using: .utf8) {
            do {
                let entitlements = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                return entitlements ?? [:]
            } catch {
                logger.error(message: "Failed to parse entitlements JSON: \(error)")
            }
        }
        
        // Try to parse as direct dictionary
        if let entitlementsDict = rawValue as? [String: Any] {
            return entitlementsDict
        }
        
        return [:]
    }
    
    /// Get a specific entitlement by feature key
    /// - Parameter featureKey: The feature key to look for
    /// - Returns: Entitlement value if found, nil otherwise
    public func getEntitlement(featureKey: String) -> Any? {
        let entitlements = getEntitlements()
        return entitlements[featureKey]
    }
    
    /// Check if user has a specific entitlement
    /// - Parameter featureKey: The feature key to check
    /// - Returns: True if user has the entitlement, false otherwise
    public func hasEntitlement(featureKey: String) -> Bool {
        return getEntitlement(featureKey: featureKey) != nil
    }
    
    // MARK: - HTTP API Methods (Server-side Entitlements)
    
    /// Fetch entitlements from the server with pagination support
    /// - Parameters:
    ///   - pageSize: Number of results per page (optional)
    ///   - startingAfter: Token to get the next page of results (optional)
    /// - Returns: EntitlementsResponse with pagination metadata
    /// - Throws: AuthError if not authenticated or network error
    public func fetchEntitlements(pageSize: Int? = nil, startingAfter: String? = nil) async throws -> EntitlementsResponse {
        guard auth.isAuthenticated() else {
            throw AuthError.notAuthenticated
        }
        
        let tokens = try await auth.getToken()
        let token = tokens.accessToken
        
        // Build URL with query parameters
        var urlComponents = URLComponents(string: "\(KindeSDKAPI.basePath)/account_api/v1/entitlements")
        var queryItems: [URLQueryItem] = []
        
        if let pageSize = pageSize {
            queryItems.append(URLQueryItem(name: "page_size", value: String(pageSize)))
        }
        
        if let startingAfter = startingAfter {
            queryItems.append(URLQueryItem(name: "starting_after", value: startingAfter))
        }
        
        urlComponents?.queryItems = queryItems.isEmpty ? nil : queryItems
        
        guard let url = urlComponents?.url else {
            throw AuthError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            logger.error(message: "Failed to fetch entitlements. Status: \(httpResponse.statusCode)")
            throw AuthError.serverError(httpResponse.statusCode)
        }
        
        do {
            let entitlementsResponse = try JSONDecoder().decode(EntitlementsResponse.self, from: data)
            return entitlementsResponse
        } catch {
            logger.error(message: "Failed to decode entitlements response: \(error)")
            throw AuthError.decodingError
        }
    }
    
    /// Fetch a single entitlement from the server
    /// - Returns: EntitlementResponse with the entitlement data
    /// - Throws: AuthError if not authenticated or network error
    public func fetchEntitlement() async throws -> EntitlementResponse {
        guard auth.isAuthenticated() else {
            throw AuthError.notAuthenticated
        }
        
        let tokens = try await auth.getToken()
        let token = tokens.accessToken
        
        guard let url = URL(string: "\(KindeSDKAPI.basePath)/account_api/v1/entitlement") else {
            throw AuthError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            logger.error(message: "Failed to fetch entitlement. Status: \(httpResponse.statusCode)")
            throw AuthError.serverError(httpResponse.statusCode)
        }
        
        do {
            let entitlementResponse = try JSONDecoder().decode(EntitlementResponse.self, from: data)
            return entitlementResponse
        } catch {
            logger.error(message: "Failed to decode entitlement response: \(error)")
            throw AuthError.decodingError
        }
    }
    
    /// Get all entitlements from server (handles pagination automatically)
    /// - Returns: Array of all entitlements
    /// - Throws: AuthError if not authenticated or network error
    public func getAllEntitlements() async throws -> [Entitlement] {
        var allEntitlements: [Entitlement] = []
        var startingAfter: String? = nil
        
        repeat {
            let response = try await fetchEntitlements(startingAfter: startingAfter)
            allEntitlements.append(contentsOf: response.data.entitlements)
            startingAfter = response.metadata.nextPageStartingAfter
        } while startingAfter != nil
        
        return allEntitlements
    }
    
    /// Get entitlements as a dictionary (convenience method)
    /// - Returns: Dictionary of entitlements with their values
    /// - Throws: AuthError if not authenticated or network error
    public func getEntitlementsDictionary() async throws -> [String: Any] {
        let entitlements = try await getAllEntitlements()
        var dictionary: [String: Any] = [:]
        
        for entitlement in entitlements {
            dictionary[entitlement.key] = entitlement.value.value
        }
        
        return dictionary
    }
    
    // MARK: - Hard Check Methods
    
    /// Check if user has a boolean entitlement with hard check
    /// - Parameters:
    ///   - featureKey: The entitlement key to check
    ///   - defaultValue: Default value if entitlement not found (hard check)
    /// - Returns: Boolean entitlement value
    public func getBooleanEntitlement(featureKey: String, defaultValue: Bool = false) -> Bool {
        let entitlements = getEntitlements()
        if let value = entitlements[featureKey] {
            if let boolValue = value as? Bool {
                return boolValue
            } else if let stringValue = value as? String {
                return Bool(stringValue) ?? defaultValue
            }
        }
        return defaultValue
    }
    
    /// Check if user has a string entitlement with hard check
    /// - Parameters:
    ///   - featureKey: The entitlement key to check
    ///   - defaultValue: Default value if entitlement not found (hard check)
    /// - Returns: String entitlement value
    public func getStringEntitlement(featureKey: String, defaultValue: String = "") -> String {
        let entitlements = getEntitlements()
        if let value = entitlements[featureKey] {
            if let stringValue = value as? String {
                return stringValue
            } else {
                return String(describing: value)
            }
        }
        return defaultValue
    }
    
    /// Check if user has a numeric entitlement with hard check
    /// - Parameters:
    ///   - featureKey: The entitlement key to check
    ///   - defaultValue: Default value if entitlement not found (hard check)
    /// - Returns: Numeric entitlement value
    public func getNumericEntitlement(featureKey: String, defaultValue: Int = 0) -> Int {
        let entitlements = getEntitlements()
        if let value = entitlements[featureKey] {
            if let intValue = value as? Int {
                return intValue
            } else if let stringValue = value as? String {
                return Int(stringValue) ?? defaultValue
            }
        }
        return defaultValue
    }
    
    /// Perform a hard check with validation and fallback
    /// - Parameters:
    ///   - checkName: Name of the check being performed
    ///   - validation: Validation function that returns the result
    ///   - fallbackValue: Fallback value if validation fails
    /// - Returns: Result of validation or fallback value
    public func performHardCheck<T>(checkName: String, validation: () -> T?, fallbackValue: T) -> T {
        if let result = validation() {
            return result
        } else {
            logger.error(message: "Hard check '\(checkName)' failed, using fallback: \(fallbackValue)")
            return fallbackValue
        }
    }
}

/// Service for managing feature flags with type-safe API
public class FeatureFlagsService {
    private unowned let auth: Auth
    private let logger: LoggerProtocol
    
    public init(auth: Auth, logger: LoggerProtocol = DefaultLogger()) {
        self.auth = auth
        self.logger = logger
    }
    
    /// Get all feature flags for the current user
    /// - Returns: Dictionary of feature flags with their values, or empty dictionary if not available
    public func getFeatureFlags() -> [String: Any] {
        guard let claim = auth.claims.getClaim(forKey: "feature_flags") else {
            return [:]
        }
        
        let rawValue = claim.value.value
        
        // Try to parse as JSON string first
        if let claimString = rawValue as? String,
           let data = claimString.data(using: .utf8) {
            do {
                let flags = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                return flags ?? [:]
            } catch {
                logger.error(message: "Failed to parse feature flags JSON: \(error)")
            }
        }
        
        // Try to parse as direct dictionary
        if let flagsDict = rawValue as? [String: Any] {
            return flagsDict
        }
        
        return [:]
    }
    
    /// Get a specific feature flag by code
    /// - Parameter code: The feature flag code to look for
    /// - Returns: Feature flag value if found, nil otherwise
    public func getFeatureFlag(code: String) -> Any? {
        let flags = getFeatureFlags()
        return flags[code]
    }
    
    /// Check if a feature flag is enabled (boolean type)
    /// - Parameters:
    ///   - code: The feature flag code to check
    ///   - defaultValue: Default value if flag not found
    /// - Returns: Boolean indicating if feature is enabled
    public func isFeatureEnabled(code: String, defaultValue: Bool = false) -> Bool {
        guard let flagValue = getFeatureFlag(code: code) else {
            return defaultValue
        }
        
        // Handle boolean values
        if let boolValue = flagValue as? Bool {
            return boolValue
        }
        
        // Handle string values that represent booleans
        if let stringValue = flagValue as? String {
            return Bool(stringValue) ?? defaultValue
        }
        
        return defaultValue
    }
}

extension Auth {
    private enum ClaimKey: String {
        case permissions = "permissions"
        case organisationCode = "org_code"
        case organisationCodes = "org_codes"
        case featureFlags = "feature_flags"
    }
}
