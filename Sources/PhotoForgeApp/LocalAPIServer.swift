import Foundation
import Network
import CryptoKit
import AppKit
import ImageIO
import UniformTypeIdentifiers
import GRDB
import PFCore
import PFDatabase
import PFPhotosBridge
import PFClassify

/// An access token another app uses. Only a SHA-256 of the secret is stored.
struct APIToken: Codable, Identifiable, Hashable {
    enum Scope: String, Codable, CaseIterable, Identifiable {
        case read, thumbnails, originals
        var id: String { rawValue }
        var label: String {
            switch self {
            case .read: "Library information (names, dates, categories, people, albums)"
            case .thumbnails: "Thumbnails"
            case .originals: "Original files"
            }
        }
    }
    var id = UUID()
    var name: String
    var secretHash: String
    var scopes: [Scope]
    var created = Date()
    var lastUsed: Date?
}

/// Read-only local API so other software can use a PhotoForge library, with permission.
/// Listens on 127.0.0.1 only; every request needs `Authorization: Bearer <token>`.
/// See docs/API.md.
@MainActor
@Observable
final class LocalAPIServer {
    private(set) var isRunning = false
    private(set) var port: UInt16 = UInt16(UserDefaults.standard.integer(forKey: "api.port") == 0 ? 8765 : UserDefaults.standard.integer(forKey: "api.port"))
    private(set) var tokens: [APIToken] = []
    private(set) var lastError: String?
    private(set) var requestsServed = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "photoforge.api")
    private weak var model: AppModel?

    static var tokensURL: URL { AppModel.supportDir.appendingPathComponent("api-tokens.json") }

    init() {
        if let d = try? Data(contentsOf: Self.tokensURL), let t = try? JSONDecoder().decode([APIToken].self, from: d) { tokens = t }
    }

    func restoreIfEnabled(model: AppModel) {
        self.model = model
        if UserDefaults.standard.bool(forKey: "api.enabled") { start(model: model) }
    }

    func start(model: AppModel, port newPort: UInt16? = nil) {
        self.model = model
        stop()
        if let p = newPort { port = p; UserDefaults.standard.set(Int(p), forKey: "api.port") }
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback          // never reachable from the network
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.isRunning = true; self?.lastError = nil
                    case .failed(let e): self?.isRunning = false; self?.lastError = e.localizedDescription
                    case .cancelled: self?.isRunning = false
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
            UserDefaults.standard.set(true, forKey: "api.enabled")
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop(persist: Bool = false) {
        listener?.cancel()
        listener = nil
        isRunning = false
        if persist { UserDefaults.standard.set(false, forKey: "api.enabled") }
    }

    // MARK: Tokens

    /// Returns the secret once; only its hash is kept.
    func createToken(name: String, scopes: [APIToken.Scope]) -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let secret = "pf_" + Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        tokens.append(APIToken(name: name.isEmpty ? "Untitled app" : name, secretHash: Self.hash(secret), scopes: scopes))
        saveTokens()
        model?.db?.log("privacy", "Created access token “\(name)” (\(scopes.map(\.rawValue).joined(separator: ", ")))")
        return secret
    }

    func revoke(_ id: UUID) {
        let name = tokens.first { $0.id == id }?.name ?? ""
        tokens.removeAll { $0.id == id }
        saveTokens()
        model?.db?.log("privacy", "Revoked access token “\(name)”")
    }

    private func saveTokens() {
        try? FileManager.default.createDirectory(at: AppModel.supportDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(tokens) {
            try? d.write(to: Self.tokensURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.tokensURL.path)
        }
    }

    nonisolated static func hash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        Self.receiveRequest(conn, buffer: Data()) { [weak self] req in
            Task { @MainActor in
                guard let self else { conn.cancel(); return }
                let resp = await self.handle(req)
                self.requestsServed += 1
                conn.send(content: resp.serialized(), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    struct Request: Sendable {
        var method = "", path = "", query: [String: String] = [:], headers: [String: String] = [:]
    }

    struct Response: Sendable, Error {
        var status: Int
        var contentType = "application/json; charset=utf-8"
        var body: Data
        static func json(_ obj: Any, status: Int = 200) -> Response {
            Response(status: status, body: (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data())
        }
        static func error(_ status: Int, _ message: String) -> Response { .json(["error": message], status: status) }
        func serialized() -> Data {
            let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                          405: "Method Not Allowed", 503: "Service Unavailable"][status] ?? "Error"
            var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
            head += "Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
            return Data(head.utf8) + body
        }
    }

    nonisolated static func receiveRequest(_ conn: NWConnection, buffer: Data, done: @escaping @Sendable (Request?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                done(parse(buf.subdata(in: 0..<r.lowerBound)))
            } else if isComplete || error != nil || buf.count > 65_536 {
                done(nil)
            } else {
                receiveRequest(conn, buffer: buf, done: done)
            }
        }
    }

    nonisolated static func parse(_ head: Data) -> Request? {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let comps = URLComponents(string: String(parts[1])) else { return nil }
        var r = Request(method: String(parts[0]), path: comps.path)
        for q in comps.queryItems ?? [] { r.query[q.name] = q.value ?? "" }
        for l in lines.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            r.headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        return r
    }

    // MARK: Routing


    /// Which token (by index) a request carries, or the 401 to send back.
    nonisolated static func authenticate(_ req: Request, tokens: [APIToken]) -> Swift.Result<Int, Response> {
        let auth = req.headers["authorization"] ?? ""
        guard auth.lowercased().hasPrefix("bearer ") else { return .failure(.error(401, "Missing token. Send 'Authorization: Bearer <token>'.")) }
        let h = hash(String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces))
        guard let i = tokens.firstIndex(where: { $0.secretHash == h }) else { return .failure(.error(401, "Invalid or revoked token")) }
        return .success(i)
    }

    /// The permission a path needs: file bytes need `originals`, images need `thumbnails`, the rest `read`.
    nonisolated static func requiredScope(_ path: String) -> APIToken.Scope {
        if path.hasSuffix("/original") { return .originals }
        if path.hasSuffix("/thumbnail") { return .thumbnails }
        return .read
    }

    func handle(_ req: Request?) async -> Response {
        guard let req else { return .error(400, "Malformed request") }
        guard req.method == "GET" else { return .error(405, "Only GET is supported; the API is read-only") }
        // Authentication
        let ti: Int
        switch Self.authenticate(req, tokens: tokens) {
        case .failure(let r): return r
        case .success(let i): ti = i
        }
        tokens[ti].lastUsed = .now
        let token = tokens[ti]
        if !token.scopes.contains(Self.requiredScope(req.path)) {
            return .error(403, "This token doesn't allow '\(Self.requiredScope(req.path).rawValue)'")
        }
        func need(_ s: APIToken.Scope) -> Response? { token.scopes.contains(s) ? nil : .error(403, "This token doesn't allow '\(s.rawValue)'") }

        guard let model, let db = model.db, let sid = model.activeLibraryID else { return .error(503, "No library is open") }
        let parts = req.path.split(separator: "/").map(String.init)      // ["v1", "assets", "12", "thumbnail"]
        guard parts.first == "v1" else { return .error(404, "Unknown path. Endpoints start with /v1/.") }
        let rest = Array(parts.dropFirst())
        do {
            switch rest.first {
            case "library":
                if let e = need(.read) { return e }
                return .json(["name": model.activeEntry?.name ?? "", "kind": model.activeEntry?.kind.rawValue ?? "",
                              "id": model.activeEntry?.id.uuidString ?? "",
                              "photos": model.stats.photos, "videos": model.stats.videos,
                              "people": model.namedPeople.count, "albums": model.albums.count, "api": 1])
            case "categories":
                if let e = need(.read) { return e }
                return .json(PhotoCategory.allCases.map { ["id": $0.rawValue, "title": $0.title, "count": model.categoryMembers[$0]?.count ?? 0] })
            case "people":
                if let e = need(.read) { return e }
                return .json(model.personSummaries().map { ["id": $0.id, "name": $0.name ?? NSNull(), "photos": $0.photoCount] as [String: Any] })
            case "albums":
                if let e = need(.read) { return e }
                return .json(model.albums.map { ["id": $0.id, "title": $0.title, "parent": $0.parentID ?? NSNull(),
                                                 "isFolder": $0.isFolder, "smart": $0.isSmart, "count": model.members(of: $0).count] as [String: Any] })
            case "tags":
                if let e = need(.read) { return e }
                return .json(model.tagNames.map { ["name": $0, "count": model.userTags[$0]?.count ?? 0] as [String: Any] })
            case "assets":
                if rest.count == 1 {
                    if let e = need(.read) { return e }
                    return .json(try await listAssets(req.query, db: db, sid: sid, model: model))
                }
                guard let id = Int64(rest[1]), let asset = model.assetsByID[id] else { return .error(404, "No such item") }
                if rest.count == 2 {
                    if let e = need(.read) { return e }
                    var item = Self.item(asset, categories: model.categoryMembers)
                    item["people"] = model.faces(in: id).compactMap { model.person(forFace: $0.id)?.name }
                    item["albums"] = model.albumsContaining(id).map(\.id)
                    item["tags"] = model.tags(of: id)
                    item["text"] = (try? db.ocrText(assetID: id)) ?? NSNull()
                    return .json(item)
                }
                switch rest[2] {
                case "thumbnail":
                    if let e = need(.thumbnails) { return e }
                    let size = min(2048, max(64, Double(req.query["size"] ?? "") ?? 512))
                    guard let img = await model.mediaSource.thumbnail(for: asset.localIdentifier, side: size),
                          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let jpeg = Self.jpeg(cg) else { return .error(404, "No thumbnail available") }
                    return Response(status: 200, contentType: "image/jpeg", body: jpeg)
                case "original":
                    if let e = need(.originals) { return e }
                    guard !asset.isVideo else { return .error(404, "Originals are available for photos only") }
                    let data = try await model.mediaSource.fullImageData(for: asset.localIdentifier)
                    let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }
                    let mime = type.flatMap { UTType($0)?.preferredMIMEType } ?? "application/octet-stream"
                    return Response(status: 200, contentType: mime, body: data)
                default:
                    return .error(404, "Unknown path")
                }
            default:
                return .error(404, "Unknown path. See /v1/library, /v1/assets, /v1/people, /v1/albums, /v1/categories.")
            }
        } catch {
            return .error(503, error.localizedDescription)
        }
    }

    private func listAssets(_ q: [String: String], db: AppDatabase, sid: Int64, model: AppModel) async throws -> [String: Any] {
        var rows = model.assets
        if let t = q["type"], ["image", "video"].contains(t) { rows = rows.filter { $0.mediaType == t } }
        if let c = q["category"], let cat = PhotoCategory(rawValue: c) { let ids = model.categoryMembers[cat] ?? []; rows = rows.filter { ids.contains($0.id) } }
        if let t = q["tag"] { let ids = model.userTags.first { $0.key.caseInsensitiveCompare(t) == .orderedSame }?.value ?? []; rows = rows.filter { ids.contains($0.id) } }
        if let a = q["album"], let aid = Int64(a) { let ids = model.albumAssetIDs(aid); rows = rows.filter { ids.contains($0.id) } }
        if let p = q["person"], let pid = Int64(p), let person = model.people.first(where: { $0.personID == pid }) {
            let ids = Set(person.faces.map(\.assetID)); rows = rows.filter { ids.contains($0.id) }
        }
        if let text = q["q"], !text.isEmpty { let ids = await model.searchText(text); rows = rows.filter { ids.contains($0.id) } }
        let limit = min(1000, max(1, Int(q["limit"] ?? "") ?? 100)), offset = max(0, Int(q["offset"] ?? "") ?? 0)
        let page = rows.dropFirst(offset).prefix(limit)
        return ["total": rows.count, "offset": offset, "limit": limit,
                "items": page.map { Self.item($0, categories: model.categoryMembers) }]
    }

    static let iso = ISO8601DateFormatter()

    static func item(_ a: AssetRow, categories: [PhotoCategory: Set<Int64>]) -> [String: Any] {
        ["id": a.id, "name": a.displayName, "filename": a.originalFilename ?? NSNull(), "type": a.mediaType,
         "created": a.creationDate.map { iso.string(from: $0) } ?? NSNull(), "width": a.pixelWidth, "height": a.pixelHeight,
         "duration": a.duration, "favorite": a.favorite,
         "categories": PhotoCategory.allCases.filter { categories[$0]?.contains(a.id) == true }.map(\.rawValue)]
    }

    nonisolated static func jpeg(_ cg: CGImage) -> Data? {
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? d as Data : nil
    }
}
