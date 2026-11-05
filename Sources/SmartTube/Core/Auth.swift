import Foundation

struct Account: Codable, Identifiable, Equatable {
    var id: String { refreshToken + (pageId ?? "") }
    var refreshToken: String
    var name: String
    var email: String?
    var handle: String?
    var photo: URL?
    /// Brand account page id ("X-Goog-PageId" header)
    var pageId: String?
}

struct DeviceCode {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let interval: Int
    let expiresAt: Date
}

/// TV-style device code sign-in (youtube.com/activate), multi-account. Port of SmartTube's AuthService V2.
actor AuthService {
    static let shared = AuthService()

    private let scope = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"
    private var cachedToken: (token: String, expires: Date, account: String)?

    private(set) var accounts: [Account] = []
    private(set) var selectedId: String?

    private let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SmartTube", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("accounts.json")
    }()

    private struct Store: Codable { var accounts: [Account]; var selected: String? }

    init() {
        if let d = try? Data(contentsOf: storeURL), let s = try? JSONDecoder().decode(Store.self, from: d) {
            accounts = s.accounts
            selectedId = s.selected
        }
    }

    var selected: Account? { accounts.first { $0.id == selectedId } }
    var isSignedIn: Bool { selected != nil }

    private func save() {
        let s = Store(accounts: accounts, selected: selectedId)
        if let d = try? JSONEncoder().encode(s) {
            try? d.write(to: storeURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        }
    }

    private var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: "deviceId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceId")
        return id
    }

    private func postOAuth(_ path: String, _ body: [String: Any]) async throws -> JSON {
        let url = URL(string: "https://www.youtube.com/o/oauth2/\(path)")!
        let (d, _) = try await HTTP.shared.data(url, method: "POST",
                                                headers: ["Content-Type": "application/json", "User-Agent": InnerTubeClient.tv.userAgent],
                                                body: body.jsonData())
        return try JSON(data: d)
    }

    // MARK: Sign in

    func requestDeviceCode() async throws -> DeviceCode {
        let client = try await AppInfo.shared.oauthClient()
        let j = try await postOAuth("device/code", ["client_id": client.id, "device_id": deviceId, "model_name": "ytlr::", "scope": scope])
        guard let dc = j["device_code"].string, let uc = j["user_code"].string else {
            throw APIError.other(j["error"].string ?? "Could not get sign-in code")
        }
        return DeviceCode(deviceCode: dc, userCode: uc,
                          verificationURL: j["verification_url"].string ?? "https://yt.be/activate",
                          interval: j["interval"].int ?? 5,
                          expiresAt: Date().addingTimeInterval(TimeInterval(j["expires_in"].int ?? 1800)))
    }

    /// Polls until the user enters the code. Returns the new account.
    func waitForSignIn(_ code: DeviceCode) async throws -> Account {
        let client = try await AppInfo.shared.oauthClient()
        while Date() < code.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(max(code.interval, 3)) * 1_000_000_000)
            let j = try await postOAuth("token", ["code": code.deviceCode, "client_id": client.id, "client_secret": client.secret,
                                                  "grant_type": "http://oauth.net/grant_type/device/1.0"])
            if let refresh = j["refresh_token"].string, let access = j["access_token"].string {
                let expires = Date().addingTimeInterval(TimeInterval(j["expires_in"].int ?? 3600) - 60)
                var account = Account(refreshToken: refresh, name: "YouTube account")
                cachedToken = (access, expires, account.id)
                let infos = (try? await fetchAccounts(accessToken: access)) ?? []
                if let info = infos.first(where: { $0.pageId == nil }) ?? infos.first {
                    account.name = info.name; account.email = info.email; account.handle = info.handle; account.photo = info.photo
                }
                accounts.removeAll { $0.refreshToken == refresh }
                accounts.append(account)
                selectedId = account.id
                cachedToken = (access, expires, account.id)
                save()
                return account
            }
            let err = j["error"].string ?? ""
            if err == "authorization_pending" || err == "slow_down" { continue }
            if !err.isEmpty { throw APIError.other("Sign-in failed: \(err)") }
        }
        throw APIError.other("Sign-in code expired")
    }

    /// Lists owner + brand accounts reachable from the current refresh token.
    func fetchAccounts(accessToken: String) async throws -> [Account] {
        let visitor = await AppInfo.shared.visitorData()
        var body: [String: Any] = ["accountReadMask": ["returnOwner": true, "returnBrandAccounts": true, "returnPersonaAccounts": false]]
        body["context"] = InnerTube.context(.tv, browse: false, visitorData: visitor)
        let (d, _) = try await HTTP.shared.data(URL(string: InnerTube.base + "account/accounts_list?prettyPrint=false")!, method: "POST",
                                                headers: ["Content-Type": "application/json", "Authorization": "Bearer \(accessToken)",
                                                          "User-Agent": InnerTubeClient.tv.userAgent],
                                                body: body.jsonData())
        let j = try JSON(data: d)
        let refresh = selected?.refreshToken ?? ""
        return j.findAll("accountItem").map { a in
            Account(refreshToken: refresh,
                    name: a["accountName"].text ?? "Account",
                    email: a["accountByline"].text,
                    handle: a["channelHandle"].text,
                    photo: a["accountPhoto"].bestThumbnail,
                    pageId: a.first("pageId").string)
        }
    }

    /// Brand accounts available for the signed in user.
    func brandAccounts() async throws -> [Account] {
        guard let sel = selected else { return [] }
        let token = try await accessToken()
        return try await fetchAccounts(accessToken: token).map { var a = $0; a.refreshToken = sel.refreshToken; return a }
    }

    func addOrSelect(_ account: Account) {
        if !accounts.contains(where: { $0.id == account.id }) { accounts.append(account) }
        selectedId = account.id
        cachedToken = nil
        save()
    }

    func select(_ id: String?) {
        selectedId = id
        cachedToken = nil
        save()
    }

    func remove(_ id: String) {
        accounts.removeAll { $0.id == id }
        if selectedId == id { selectedId = accounts.first?.id }
        cachedToken = nil
        save()
    }

    func invalidateAccessToken() { cachedToken = nil }

    func pageId() -> String? { selected?.pageId }

    // MARK: Tokens

    func accessToken() async throws -> String {
        guard let acc = selected else { throw APIError.notSignedIn }
        if let c = cachedToken, c.account == acc.id, c.expires > Date() { return c.token }
        let client = try await AppInfo.shared.oauthClient()
        let j = try await postOAuth("token", ["refresh_token": acc.refreshToken, "client_id": client.id,
                                              "client_secret": client.secret, "grant_type": "refresh_token"])
        guard let token = j["access_token"].string else {
            throw APIError.other("Token refresh failed: \(j["error"].string ?? "unknown")")
        }
        cachedToken = (token, Date().addingTimeInterval(TimeInterval(j["expires_in"].int ?? 3600) - 60), acc.id)
        return token
    }
}
