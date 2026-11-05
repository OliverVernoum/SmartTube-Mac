import Foundation
import JavaScriptCore

/// Solves YouTube "n" (throttling) and "sig" (signature cipher) challenges by running
/// yt-dlp's ejs solver (bundled, same as SmartTube) inside JavaScriptCore.
actor JSSolver {
    static let shared = JSSolver()

    private var context: JSContext?
    private final class ErrorBox { var message: String? }
    private let errors = ErrorBox()
    /// Preprocessed player code keyed by player url (expensive to produce: ~1-2 s).
    private var preprocessed: [URL: String] = [:]
    /// Solved values cache: "n:<value>" / "sig:<value>" per player.
    private var solved: [String: String] = [:]

    private func makeContext() throws -> JSContext {
        if let context { return context }
        guard let ctx = JSContext() else { throw APIError.other("JavaScriptCore unavailable") }
        let box = errors
        ctx.exceptionHandler = { _, ex in box.message = ex?.toString() }
        for name in ["polyfill.js", "meriyah-6.1.4.min.js", "astring-1.9.0.min.js", "yt.solver.core.js"] {
            guard let url = Self.resourceURL(name),
                  let code = try? String(contentsOf: url, encoding: .utf8) else {
                throw APIError.other("Missing solver script \(name)")
            }
            ctx.evaluateScript(code, withSourceURL: url)
            if let e = errors.message { errors.message = nil; throw APIError.other("Solver init failed (\(name)): \(e)") }
        }
        context = ctx
        return ctx
    }

    /// Solves challenges for a player. Returns map challenge -> solution for each type.
    func solve(player: AppInfo.PlayerJS, n: [String], sig: [String]) throws -> (n: [String: String], sig: [String: String]) {
        var nOut: [String: String] = [:]
        var sOut: [String: String] = [:]
        let key = player.url.absoluteString
        let nTodo = Array(Set(n)).filter { c in
            if let v = solved["\(key)|n|\(c)"] { nOut[c] = v; return false }
            return true
        }
        let sTodo = Array(Set(sig)).filter { c in
            if let v = solved["\(key)|sig|\(c)"] { sOut[c] = v; return false }
            return true
        }
        if nTodo.isEmpty && sTodo.isEmpty { return (nOut, sOut) }

        let ctx = try makeContext()
        var requests: [[String: Any]] = []
        if !nTodo.isEmpty { requests.append(["type": "n", "challenges": nTodo]) }
        if !sTodo.isEmpty { requests.append(["type": "sig", "challenges": sTodo]) }

        var input: [String: Any]
        if let pre = preprocessed[player.url] ?? loadPreprocessed(player.url) {
            input = ["type": "preprocessed", "preprocessed_player": pre, "requests": requests]
        } else {
            input = ["type": "player", "player": player.code, "requests": requests, "output_preprocessed": true]
        }

        guard let jsc = ctx.objectForKeyedSubscript("jsc"), !jsc.isUndefined else { throw APIError.other("Solver entrypoint missing") }
        errors.message = nil
        let result = jsc.call(withArguments: [input])
        if let e = errors.message { errors.message = nil; throw APIError.other("Solver error: \(e)") }
        guard let result else { throw APIError.other("Solver returned nothing") }
        let out = JSON(any: result.toObject())

        if out["type"].string == "error" {
            // preprocessed code may be stale: drop it so the next call re-parses
            preprocessed[player.url] = nil
            throw APIError.other("Solver error: \(out["error"].string ?? "unknown")")
        }
        if let pre = out["preprocessed_player"].string {
            preprocessed[player.url] = pre
            DiskCache.store("preprocessed-\(player.url.path)", Data(pre.utf8))
        }
        for (i, resp) in out["responses"].array.enumerated() {
            guard i < requests.count, resp["type"].string == "result" else { continue }
            let type = requests[i]["type"] as? String ?? "n"
            for (k, v) in resp["data"].object {
                guard let v = v.string else { continue }
                solved["\(key)|\(type)|\(k)"] = v
                if type == "n" { nOut[k] = v } else { sOut[k] = v }
            }
        }
        return (nOut, sOut)
    }

    /// App bundle (Contents/Resources/nsigsolver) first; SwiftPM resource bundle when run via `swift run`.
    static func resourceURL(_ name: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "nsigsolver") { return u }
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        for c in candidates.compactMap({ $0 }) {
            let u = c.appendingPathComponent("SmartTube_SmartTube.bundle/nsigsolver/\(name)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
            let u2 = c.appendingPathComponent("SmartTube_SmartTube.bundle/Contents/Resources/nsigsolver/\(name)")
            if FileManager.default.fileExists(atPath: u2.path) { return u2 }
        }
        return nil
    }

    private func loadPreprocessed(_ url: URL) -> String? {
        guard let d = DiskCache.load("preprocessed-\(url.path)") else { return nil }
        let s = String(decoding: d, as: UTF8.self)
        preprocessed[url] = s
        return s
    }
}
