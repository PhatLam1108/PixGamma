import Foundation
import Network

/// Minimal local HTTP/1.1 API (no external dependencies).
///
///   GET  /health
///   GET  /v1/models
///   POST /v1/analyze            body = image bytes          → JSON
///   POST /v1/upscale?…          body = image bytes          → image bytes (or JSON with Accept: application/json)
///
/// Query parameters for /v1/upscale (strengths are 0–100, like the CLI):
///   mode=auto|standard|fidelity|art|lowres  scale=4 | width=… | height=…
///   denoise= sharpen= compression= detail= texture= contrast= dehalo= text=0|1 face= face_style=realistic|creative face_fidelity=  color=0|1  device=gpu|all|ane|cpu
///   format=png|jpg|tiff|heic  quality=0–100
public final class APIServer: @unchecked Sendable {
    public static let version = "0.2.1"
    public let port: UInt16
    public let host: String
    public let maxBodyBytes = 256 * 1024 * 1024
    private var listener: NWListener?
    private let jobs = DispatchQueue(label: "pixgamma.api.jobs") // one job at a time
    private let log: @Sendable (String) -> Void

    public init(host: String = "127.0.0.1", port: UInt16 = 8765, log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.host = host
        self.port = port
        self.log = log
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { [log, host, port] state in
            switch state {
            case .ready: log("PixGamma API đang chạy tại http://\(host):\(port)")
            case .failed(let e): log("API lỗi: \(e)")
            default: break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    public func stop() { listener?.cancel() }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Request.parse(buf) {
                self.respond(conn, to: req)
            } else if buf.count > self.maxBodyBytes {
                self.send(conn, Response.json(413, ["error": "body quá lớn"]))
            } else if complete || error != nil {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func send(_ conn: NWConnection, _ resp: Response) {
        conn.send(content: resp.serialized(), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func respond(_ conn: NWConnection, to req: Request) {
        log("\(req.method) \(req.path)")
        switch (req.method, req.path) {
        case ("GET", "/health"):
            send(conn, .json(200, ["status": "ok", "version": Self.version]))
        case ("GET", "/v1/models"):
            send(conn, .json(200, Self.modelsInfo()))
        case ("POST", "/v1/analyze"):
            jobs.async { self.send(conn, self.analyze(req)) }
        case ("POST", "/v1/upscale"):
            jobs.async { self.send(conn, self.upscale(req)) }
        default:
            send(conn, .json(404, ["error": "không có endpoint \(req.method) \(req.path)"]))
        }
    }

    public static func modelsInfo() -> [String: Any] {
        let store = ModelStore.shared
        let modes: [[String: Any]] = EnhanceMode.allCases.map { m in
            let nets = ModelCatalog.networks(for: m)
            return [
                "id": m.rawValue, "name": m.displayName, "description": m.summary,
                "native_scales": nets.filter { store.isAvailable($0.file) || store.isAvailable($0.file + "_dn050") }.map(\.scale),
                "available": nets.contains { store.isAvailable($0.file) },
            ]
        }
        return [
            "modes": modes,
            "face_recovery": FaceStyle.allCases.filter { store.isAvailable($0.file) }.map(\.rawValue),
        ]
    }

    // MARK: - Jobs

    private func analyze(_ req: Request) -> Response {
        do {
            let loaded = try ImageFile.load(data: req.body)
            let faces = FaceRestorer.detect(loaded.image).count
            return .codable(200, Analyzer.analyze(loaded.image, faceCount: faces))
        } catch {
            return .json(400, ["error": error.localizedDescription])
        }
    }

    private func upscale(_ req: Request) -> Response {
        let q = req.query
        func pct(_ k: String) -> Double? { q[k].flatMap(Double.init).map { min(max($0, 0), 100) / 100 } }
        do {
            var size = OutputSize.factor(q["scale"].flatMap(Double.init) ?? 4)
            if let w = q["width"].flatMap(Int.init) { size = .width(w) }
            if let h = q["height"].flatMap(Int.init) { size = .height(h) }
            let format = q["format"].flatMap(OutputFormat.init(rawValue:)) ?? .png
            let quality = q["quality"].flatMap(Double.init) ?? 95
            let wantsJSON = req.headers["accept"]?.contains("application/json") == true

            let loaded = try ImageFile.load(data: req.body)
            var o = UpscaleOptions()
            if let m = q["mode"] {
                guard let mode = EnhanceMode.parse(m) else { throw PixGammaError.invalidOption("mode=\(m)") }
                o.mode = mode
            }
            o.size = size
            if let c = pct("creativity") { o.creativity = c }; if let r = pct("resemblance") { o.resemblance = r }; o.prompt = q["prompt"]
            o.denoise = pct("denoise"); o.sharpen = pct("sharpen"); o.compression = pct("compression"); o.faceRecovery = pct("face")
            o.detail = pct("detail"); o.texture = pct("texture")
            o.contrast = pct("contrast"); o.protectText = q["text"] != "0"
            if let d = pct("dehalo") { o.dehalo = d }
            o.faceStyle = q["face_style"].flatMap(FaceStyle.init(rawValue:)) ?? .realistic
            if let f = pct("face_fidelity") { o.faceFidelity = f }
            o.preserveColor = q["color"] != "0"
            o.device = q["device"].flatMap(ComputeDevice.init(rawValue:)) ?? .gpu
            let result = try Upscaler.upscale(loaded.image, options: o)
            let data = try ImageFile.encode(result.image, settings: ExportSettings(format: format, jpegQuality: quality / 100),
                                        sourceProperties: loaded.properties)
            let reportJSON: Any = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(result.report))) ?? NSNull()
            if wantsJSON {
                return .json(200, ["report": reportJSON, "format": format.fileExtension, "image_base64": data.base64EncodedString()])
            }
            var resp = Response(status: 200, contentType: Self.mime(format), body: data)
            if let r = try? JSONSerialization.data(withJSONObject: reportJSON), let s = String(data: r, encoding: .utf8) {
                resp.headers["X-PixGamma-Report"] = s
            }
            return resp
        } catch {
            return .json(400, ["error": error.localizedDescription])
        }
    }

    static func mime(_ f: OutputFormat) -> String {
        switch f {
        case .jpg: return "image/jpeg"
        case .tiff: return "image/tiff"
        case .heic: return "image/heic"
        default: return "image/png"
        }
    }

    static func sniffExtension(_ d: Data) -> String {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0x49, 0x49, 0x2A]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if b.count >= 12, String(bytes: b[4..<8], encoding: .ascii) == "ftyp" { return "heic" }
        return "png"
    }
}

// MARK: - HTTP primitives

struct Request {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    /// Returns nil until the full request (headers + Content-Length body) has arrived.
    static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let c = line.firstIndex(of: ":") else { continue }
            headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let comps = URLComponents(string: String(start[1]))
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(start[0]), path: comps?.path ?? "/", query: query, headers: headers,
                       body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }
}

struct Response {
    var status: Int
    var contentType: String
    var body: Data
    var headers: [String: String] = [:]

    static func json(_ status: Int, _ obj: Any) -> Response {
        let body = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return Response(status: status, contentType: "application/json; charset=utf-8", body: body)
    }

    static func codable<T: Encodable>(_ status: Int, _ value: T) -> Response {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return Response(status: status, contentType: "application/json; charset=utf-8", body: (try? enc.encode(value)) ?? Data())
    }

    func serialized() -> Data {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 413: "Payload Too Large"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}
