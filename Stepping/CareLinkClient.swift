import Foundation
import AuthenticationServices
import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Medtronic CareLink (EU / outside-US) client.
///
/// Flow (ports ondrej1024/carelink-python-client Auth0 flow):
/// discovery -> authorize (user logs in with CareLink username+passcode in a
/// secure web sheet) -> code -> tokens (Keychain) -> users/me -> display/message.
/// Tokens auto-refresh; the user only logs in again if refresh fails.
@MainActor
final class CareLinkClient: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = CareLinkClient()

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
#if os(iOS)
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
#else
        ASPresentationAnchor()
#endif
    }

    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var clientId: String
        var scope: String?
        var tokenURL: String
        var baseCareLink: String
        var baseCumulus: String
        var username: String?
        var role: String?
        var patientId: String?
    }

    struct GlucosePoint: Identifiable {
        let id = UUID()
        let date: Date
        let mgdl: Double
    }

    @Published var state: String = "Logged out"
    @Published var isLoggedIn = false
    @Published var username: String?
    @Published var diagnostics: String = ""

    private static let discoveryURL = URL(string:
        "https://clcloud.minimed.eu/connect/carepartner/v13/discover/android/3.6")!
    // Fallbacks = live values as of Oct 2026 (discovery is re-queried each login).
    private static let fallback = (
        tokenURL: "https://carelink-login.minimed.eu:443/oauth/token",
        authorizeURL: "https://carelink-login.minimed.eu:443/authorize",
        clientId: "PeAhkbhQWlQRxJiQxWfcFBiGus1lxfe9",
        scope: "profile openid offline_access",
        redirectURI: "com.medtronic.carepartner:/sso",
        audience: "carepartner.patient.ous",
        baseCareLink: "https://carelink.minimed.eu/api/carepartner/v2",
        baseCumulus: "https://clcloud.minimed.eu/connect/carepartner/v13"
    )
    private static let ua = "Dalvik/2.1.0 (Linux; U; Android 10; Nexus 5X Build/QQ3A.200805.001)"
    private var session: ASWebAuthenticationSession?
    private var altEndpoint: String?
    private var guardianPreferred: Bool {
        get { UserDefaults.standard.bool(forKey: "carelink.guardianFirst") }
        set { UserDefaults.standard.set(newValue, forKey: "carelink.guardianFirst") }
    }
    private var tokens: Tokens? { didSet { persist() } }

    override init() {
        super.init()
        if let data = Keychain.load(account: "tokens"),
           let t = try? JSONDecoder().decode(Tokens.self, from: data) {
            tokens = t
            username = t.username
            isLoggedIn = true
            state = "Session restored"
        }
        if username == nil, let u = Keychain.load(account: "username"),
           let s = String(data: u, encoding: .utf8) {
            username = s
        }
    }

    private func persist() {
        if let t = tokens, let d = try? JSONEncoder().encode(t) {
            Keychain.save(d, account: "tokens")
            if let u = t.username, let ud = u.data(using: .utf8) {
                Keychain.save(ud, account: "username")
            }
        }
    }

    func logout() {
        tokens = nil
        Keychain.delete(account: "tokens")
        // keep username for convenience
        isLoggedIn = false
        username = tokens?.username
        if username == nil, let u = Keychain.load(account: "username"),
           let s = String(data: u, encoding: .utf8) { username = s }
        state = "Logged out"
    }

    // MARK: - Login

    struct SSOConfig {
        var authorizeURL: String
        var tokenURL: String
        var clientId: String
        var scope: String
        var redirectURI: String
        var audience: String
        var baseCareLink: String
        var baseCumulus: String
    }

    func resolveSSO() async throws -> SSOConfig {
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.discoveryURL)
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cps = j["CP"] as? [[String: Any]],
                  let eu = cps.first(where: { ($0["region"] as? String) == "EU" }),
                  let key = eu["UseSSOConfiguration"] as? String,
                  let ssoURL = eu[key] as? String,
                  let baseCL = eu["baseUrlCareLink"] as? String,
                  let baseCU = eu["baseUrlCumulus"] as? String,
                  let url = URL(string: ssoURL) else {
                throw NSError(domain: "discovery", code: 1)
            }
            let (sdata, _) = try await URLSession.shared.data(from: url)
            guard let s = try? JSONSerialization.jsonObject(with: sdata) as? [String: Any],
                  let server = s["server"] as? [String: Any],
                  let host = server["hostname"] as? String,
                  let port = server["port"] as? Int,
                  let client = s["client"] as? [String: Any],
                  let eps = s["system_endpoints"] as? [String: Any] else {
                throw NSError(domain: "sso", code: 2)
            }
            var prefix = (server["prefix"] as? String) ?? ""
            if prefix.hasPrefix("/") { prefix = String(prefix.dropFirst()) }
            var base = "https://\(host):\(port)"
            if !prefix.isEmpty { base += "/\(prefix)" }
            return SSOConfig(
                authorizeURL: base + ((eps["authorization_endpoint_path"] as? String) ?? "/authorize"),
                tokenURL: base + ((eps["token_endpoint_path"] as? String) ?? "/oauth/token"),
                clientId: (client["client_id"] as? String) ?? Self.fallback.clientId,
                scope: (client["scope"] as? String) ?? Self.fallback.scope,
                redirectURI: (client["redirect_uri"] as? String) ?? Self.fallback.redirectURI,
                audience: (client["audience"] as? String) ?? Self.fallback.audience,
                baseCareLink: baseCL, baseCumulus: baseCU)
        } catch {
            let f = Self.fallback
            return SSOConfig(authorizeURL: f.authorizeURL, tokenURL: f.tokenURL,
                             clientId: f.clientId, scope: f.scope,
                             redirectURI: f.redirectURI, audience: f.audience,
                             baseCareLink: f.baseCareLink, baseCumulus: f.baseCumulus)
        }
    }

    func login() async throws {
        state = "Contacting CareLink EU…"
        let sso = try await resolveSSO()
        var comps = URLComponents(string: sso.authorizeURL)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: sso.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: sso.scope),
            URLQueryItem(name: "redirect_uri", value: sso.redirectURI),
            URLQueryItem(name: "audience", value: sso.audience),
        ]
        guard let authURL = comps.url else { throw NSError(domain: "auth", code: 3) }
        let scheme = URL(string: sso.redirectURI)?.scheme ?? "com.medtronic.carepartner"
        let code: String = try await withCheckedThrowingContinuation { cont in
            let sess = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { url, err in
                if let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                   let c = items.first(where: { $0.name == "code" })?.value {
                    cont.resume(returning: c)
                } else {
                    cont.resume(throwing: err ?? NSError(domain: "auth-cancelled", code: 4))
                }
            }
            sess.prefersEphemeralWebBrowserSession = false
            sess.presentationContextProvider = self
            self.session = sess
            sess.start()
        }
        state = "Exchanging code…"
        var req = URLRequest(url: URL(string: sso.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        let body = "grant_type=authorization_code&client_id=\(sso.clientId)&code=\(code)&redirect_uri=\(sso.redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        req.httpBody = body.data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = j["access_token"] as? String,
              let rt = j["refresh_token"] as? String else {
            throw NSError(domain: "token", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Token exchange failed (\(String(data: data, encoding: .utf8) ?? "?"))"])
        }
        tokens = Tokens(accessToken: at, refreshToken: rt, clientId: sso.clientId,
                        scope: j["scope"] as? String, tokenURL: sso.tokenURL,
                        baseCareLink: sso.baseCareLink, baseCumulus: sso.baseCumulus)
        try await identify()
        isLoggedIn = true
        state = "Logged in"
    }

    // MARK: - API

    private func jwtExp(_ token: String) -> Double? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let d = Data(base64Encoded: b64),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        if let e = j["exp"] as? Double { return e }
        if let e = j["exp"] as? Int { return Double(e) }
        // also harvest username/country when present
        if username == nil, let td = j["token_details"] as? [String: Any],
           let u = td["preferred_username"] as? String {
            tokens?.username = u
            username = u
        }
        return nil
    }

    private func ensureToken() async throws {
        guard var t = tokens else { throw NSError(domain: "auth", code: 6) }
        if let exp = jwtExp(t.accessToken), exp - Date().timeIntervalSince1970 > 600 { return }
        var req = URLRequest(url: URL(string: t.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        req.httpBody = "grant_type=refresh_token&client_id=\(t.clientId)&refresh_token=\(t.refreshToken)".data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = j["access_token"] as? String,
              let rt = j["refresh_token"] as? String else {
            logout()
            throw NSError(domain: "refresh", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Session expired — please log in again."])
        }
        t.accessToken = at
        t.refreshToken = rt
        tokens = t
    }

    private func authed(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        if let t = tokens?.accessToken {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    func identify() async throws {
        try await ensureToken()
        guard let t = tokens else { return }
        let req = authed(URL(string: t.baseCareLink + "/users/me")!)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "users/me", code: 8)
        }
        tokens?.username = (j["username"] as? String) ?? tokens?.username
        tokens?.role = j["role"] as? String
        username = tokens?.username
        print("[CareLink] user=\(username ?? "?") role=\(tokens?.role ?? "?")")
        diagnostics = "user=\(username ?? "?") role=\(tokens?.role ?? "?")"
        if let role = tokens?.role, role.hasPrefix("CARE_PARTNER"),
           let base = tokens?.baseCareLink {
            let preq = authed(URL(string: base + "/links/patients")!)
            let (pdata, presp) = try await URLSession.shared.data(for: preq)
            if (presp as? HTTPURLResponse)?.statusCode == 200,
               let arr = try? JSONSerialization.jsonObject(with: pdata) as? [[String: Any]],
               let first = arr.first, let pu = first["username"] as? String {
                tokens?.patientId = pu
            }
        }
        await fetchAltEndpoint()
    }

    /// Legacy discovery: per-country BLE endpoint (fallback if Cumulus 204s).
    private func fetchAltEndpoint() async {
        if altEndpoint != nil { return }
        guard let csURL = URL(string: "https://carelink.minimed.eu/patient/countries/settings?countryCode=HU&language=en") else { return }
        do {
            let (csData, csResp) = try await URLSession.shared.data(for: authed(csURL))
            if (csResp as? HTTPURLResponse)?.statusCode == 200,
               let cs = try? JSONSerialization.jsonObject(with: csData) as? [String: Any],
               let ep = cs["blePereodicDataEndpoint"] as? String {
                altEndpoint = ep
                print("[CareLink] alt endpoint: \(ep)")
            } else {
                print("[CareLink] countries/settings HTTP \((csResp as? HTTPURLResponse)?.statusCode ?? 0)")
            }
        } catch {
            print("[CareLink] countries/settings failed: \(error.localizedDescription)")
        }
    }

    /// Latest Guardian sensor points (mg/dL), newest last.
    func fetchGlucose() async throws -> [GlucosePoint] {
        try await ensureToken()
        guard let t = tokens else { throw NSError(domain: "auth", code: 6) }
        print("[CareLink] stored user=\(t.username ?? "?") role=\(t.role ?? "?")")
        if t.username == nil { try await identify() }
        guard let u = tokens?.username else { throw NSError(domain: "identify", code: 9) }
        if guardianPreferred {
            // Guardian accounts go straight to the working path (no 204 dance).
            print("[CareLink] guardian-first (remembered)")
            if let g = try await fetchGuardian(username: u) { return g }
            guardianPreferred = false  // fall through to full chain
        }
        var req = authed(URL(string: tokens!.baseCumulus + "/display/message")!)
        req.httpMethod = "POST"
        var payload: [String: Any] = ["username": u]
        if let role = tokens?.role, role.hasPrefix("CARE_PARTNER") {
            payload["role"] = "carepartner"
            if let p = tokens?.patientId { payload["patientId"] = p }
        } else {
            payload["role"] = "patient"
        }
        payload["appVersion"] = "3.8.0"  // required by v13 backend (else HTTP 204)
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        var (data, resp) = try await URLSession.shared.data(for: req)
        var code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 {
            // one forced refresh + single retry (no recursion)
            tokens?.accessToken = ""
            try await ensureToken()
            var req2 = authed(URL(string: tokens!.baseCumulus + "/display/message")!)
            req2.httpMethod = "POST"
            req2.httpBody = try JSONSerialization.data(withJSONObject: payload);
            (data, resp) = try await URLSession.shared.data(for: req2)
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        }
        if code == 204 {
            // One retry: EU endpoint occasionally answers 204 transiently.
            print("[CareLink] HTTP 204, retrying once in 3s…")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            var req3 = authed(URL(string: tokens!.baseCumulus + "/display/message")!)
            req3.httpMethod = "POST"
            req3.httpBody = try JSONSerialization.data(withJSONObject: payload)
            (data, resp) = try await URLSession.shared.data(for: req3)
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        }
        if code == 204 {
            await fetchAltEndpoint()  // restored sessions never fetched it
        }
        if code == 204, let alt = altEndpoint, let altURL = URL(string: alt) {
            // Fallback: legacy per-country BLE endpoint.
            print("[CareLink] trying alt endpoint: \(alt)")
            var reqA = authed(altURL)
            reqA.httpMethod = "POST"
            reqA.httpBody = try JSONSerialization.data(withJSONObject: payload)
            (data, resp) = try await URLSession.shared.data(for: reqA)
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            print("[CareLink] alt endpoint HTTP \(code)")
        }
        if code == 204 {
            // Guardian path (no pump): single-follow last24hours or M2M endpoint.
            print("[CareLink] trying Guardian endpoints")
            if let g = try await fetchGuardian(username: u) {
                return g
            }
            // Fallback 2: legacy last24hours GET (works for some patient roles).
            let ts = Int(Date().timeIntervalSince1970 * 1000)
            if let legacy = URL(string: "https://carelink.minimed.eu/patient/connect/data?cpSerialNumber=NONE&msgType=last24hours&requestTime=\(ts)") {
                print("[CareLink] trying legacy GET endpoint")
                (data, resp) = try await URLSession.shared.data(for: authed(legacy))
                code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                print("[CareLink] legacy endpoint HTTP \(code)")
            }
        }
        guard code == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? "?"
            print("[CareLink] HTTP \(code) body: \(snippet)")
            let msg: String
            if code == 204 {
                msg = "CareLink has no phone-uploaded data (HTTP 204). " +
                      "The Guardian app must be uploading from your phone — USB uploader syncs don't appear here."
            } else {
                msg = "CareLink data request failed (HTTP \(code))."
            }
            await MainActor.run { diagnostics = "HTTP \(code): \(snippet)" }
            throw NSError(domain: "data", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let keys = j.keys.sorted().joined(separator: ",")
        print("[CareLink] top-level keys: \(keys)")
        let proot = (j["patientData"] as? [String: Any]) ?? j
        if let sgs = proot["sgs"] as? [[String: Any]], let first = sgs.first {
            print("[CareLink] sgs count: \(sgs.count), first keys: \(first.keys.sorted().joined(separator: ","))")
            print("[CareLink] first entry: \(first)")
            if let last = sgs.last { print("[CareLink] last entry: \(last)") }
        } else {
            print("[CareLink] NO sgs array. Full JSON (5KB cap): \(String(data: data.prefix(5000), encoding: .utf8) ?? "?")")
        }
        let pts = Self.parseSG(j)
        await MainActor.run {
            diagnostics = "keys: \(keys) | parsed: \(pts.count) pts"
        }
        return pts
    }

    /// Guardian (pump-less) data path, mirroring xDrip's routing:
    /// M2M multi-follow -> m2m endpoint, else single-follow last24hours.
    /// Returns nil when neither yields glucose (caller continues fallbacks).
    private func fetchGuardian(username u: String) async throws -> [GlucosePoint]? {
        var m2m = false
        if let murl = URL(string: "https://carelink.minimed.eu/patient/configuration/system/personal.cp.m2m.enabled") {
            let (mdata, mresp) = try await URLSession.shared.data(for: authed(murl))
            let mcode = (mresp as? HTTPURLResponse)?.statusCode ?? 0
            print("[CareLink] m2m.enabled HTTP \(mcode)")
            if mcode == 200,
               let mj = try? JSONSerialization.jsonObject(with: mdata) as? [String: Any],
               let v = mj["value"] as? Bool {
                m2m = v
            }
        }
        let urlStr: String
        if m2m {
            let who = tokens?.patientId ?? u
            urlStr = "https://clcloud.minimed.eu/patient/m2m/connect/data/gc/patients/\(who)"
        } else {
            urlStr = "https://clcloud.minimed.eu/patient/connect/data"
        }
        guard let url = URL(string: urlStr) else { return nil }
        print("[CareLink] Guardian GET \(urlStr)")
        let (data, resp) = try await URLSession.shared.data(for: authed(url))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        print("[CareLink] Guardian endpoint HTTP \(code), \(data.count) bytes")
        guard code == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[CareLink] Guardian body: \(String(data: data.prefix(300), encoding: .utf8) ?? "?")")
            return nil
        }
        let pts = Self.parseSG(j)
        print("[CareLink] Guardian parsed \(pts.count) pts, keys: \(j.keys.sorted().joined(separator: ","))")
        await MainActor.run {
            diagnostics = "guardian: \(pts.count) pts"
            if !pts.isEmpty { guardianPreferred = true }
        }
        return pts.isEmpty ? nil : pts
    }

    // MARK: - SG parsing (defensive: key names vary by backend version)

    static func parseSG(_ j: [String: Any]) -> [GlucosePoint] {
        // v13 shape: { metadata, patientData: { sgs: [{sg, datetime}], lastSG, ... } }
        let root = (j["patientData"] as? [String: Any]) ?? j
        var arr: [[String: Any]]?
        for k in ["sgs", "sg", "sensorGlucose", "sensorGlucoses", "glucose", "glucoseHistory"] {
            if let a = root[k] as? [[String: Any]] { arr = a; break }
        }
        // single latest-point fallback: {"lastSG": {"sg": 132, "datetime": ...}}
        if arr == nil, let single = root["lastSG"] as? [String: Any] { arr = [single] }
        if arr == nil, let single = root["currentGlucose"] as? [String: Any] { arr = [single] }
        guard let arr else { return [] }
        let unitKeys = ["sgUnits", "units", "unit"]
        var mmol = false
        for k in unitKeys {
            if let u = (j[k] as? String)?.lowercased(), u.contains("mmol") { mmol = true }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        let plain: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return f
        }()
        let zoned: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"  // +0200 / +02:00 / Z
            return f
        }()
        var pts: [GlucosePoint] = []
        for e in arr {
            var v: Double?
            for k in ["sg", "value", "glucose", "sensorGlucose"] {
                if let n = e[k] as? Double { v = n; break }
                if let n = e[k] as? Int { v = Double(n); break }
                if let s = e[k] as? String, let n = Double(s) { v = n; break }
            }
            var d: Date?
            for k in ["datetime", "dateTime", "timestamp", "time", "displayTime"] {
                if let s = e[k] as? String,
                   let dd = iso.date(from: s) ?? iso2.date(from: s) ?? zoned.date(from: s) ?? plain.date(from: s) { d = dd; break }
                if let n = e[k] as? Double { d = Date(timeIntervalSince1970: n / 1000.0); break }
                if let n = e[k] as? Int { d = Date(timeIntervalSince1970: Double(n) / 1000.0); break }
            }
            guard let vv = v, vv > 0, let dd = d else { continue }
            var mg = vv
            if mmol || vv < 30 { mg = vv * 18.0156 }
            pts.append(GlucosePoint(date: dd, mgdl: mg))
        }
        return pts.sorted { $0.date < $1.date }
    }
}
