//
//  WiFiTransferServer.swift
//  shared
//

import Foundation
import Combine
import Network
import Darwin

struct ActiveTransfer: Identifiable {
    let id: UUID
    var displayName: String   // filename (best-effort, parsed early)
    var totalBytes: Int       // from Content-Length
    var progress: Double      // 0.0 – 1.0
    var savedURL: URL?        // set once the file is written to disk
}

@MainActor
final class WiFiTransferServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var importedCount = 0
    @Published private(set) var activeTransfers: [ActiveTransfer] = []
    nonisolated(unsafe) private var _localPort: UInt16 = 8080
    var localPort: UInt16 { _localPort }

    private var listener: NWListener?

    nonisolated(unsafe) private let queue = DispatchQueue(label: "mpv.wifi-transfer", qos: .userInitiated)

    // MARK: - Lifecycle

    func start(port: UInt16 = 8080) {
        stop()
        _localPort = port
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            print("[WiFiServer] Failed to create listener: \(error)")
            return
        }
        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in self?.isRunning = (state == .ready) }
        }
        listener?.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    var localURL: String {
        "http://\(localIPAddress() ?? "unknown"):\(localPort)"
    }

    // MARK: - Connection accumulation

    /// Best-effort extraction of the first filename from the multipart preamble.
    nonisolated private func extractFirstFilename(buffer: Data, httpBodyStart: Data.Index) -> String? {
        // Prefer X-Filename header — set by the JS, always in the first TCP chunk
        let headData = buffer[..<httpBodyStart]
        if let headStr = String(data: headData, encoding: .utf8) {
            for line in headStr.components(separatedBy: "\r\n") {
                if line.lowercased().hasPrefix("x-filename:") {
                    let encoded = line.dropFirst("x-filename:".count).trimmingCharacters(in: .whitespaces)
                    if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
                        return decoded
                    }
                }
            }
        }
        // Fallback: scan body bytes for filename="..."
        let needle = Data("filename=\"".utf8)
        let body = buffer[httpBodyStart...]
        guard let fnStart = body.range(of: needle) else { return nil }
        let valueStart = fnStart.upperBound
        guard let fnEnd = body[valueStart...].range(of: Data("\"".utf8)) else { return nil }
        let name = String(data: body[valueStart..<fnEnd.lowerBound], encoding: .utf8) ?? ""
        return name.isEmpty ? nil : name
    }

    nonisolated private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        accumulate(conn: conn, buffer: Data(), contentLength: nil, transferID: nil)
    }

    nonisolated private func accumulate(conn: NWConnection, buffer: Data, contentLength: Int?, transferID: UUID?) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, isComplete, _ in
            guard let self else { return }
            var buf = buffer
            if let d = chunk { buf.append(d) }

            // Once we have all headers, try to determine Content-Length
            var cl = contentLength
            var tid = transferID
            if cl == nil, let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headStr = String(data: buf[..<headEnd.lowerBound], encoding: .utf8) ?? ""
                // No content-length → GET-like request, dispatch immediately
                if !headStr.contains("Content-Length:") {
                    self.dispatch(data: buf, conn: conn, transferID: nil)
                    return
                }
                // Parse content-length value
                for line in headStr.components(separatedBy: "\r\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-length:") {
                        cl = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
                    }
                }
                // Register a new transfer entry when we first know the total size
                if let cl, cl > 0, tid == nil {
                    let newID = UUID()
                    tid = newID
                    let name = extractFirstFilename(buffer: buf, httpBodyStart: headEnd.upperBound) ?? "Uploading\u{2026}"
                    Task { @MainActor [weak self] in
                        self?.activeTransfers.append(ActiveTransfer(id: newID, displayName: name, totalBytes: cl, progress: 0))
                    }
                }
            }

            // Update progress
            if let cl, let headEnd = buf.range(of: Data("\r\n\r\n".utf8)), let tid {
                let received = buf.count - headEnd.upperBound
                let pct = min(Double(received) / Double(cl), 1.0)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let i = self.activeTransfers.firstIndex(where: { $0.id == tid }) {
                        self.activeTransfers[i].progress = pct
                    }
                }
            }

            // Check if we have the full body
            if let cl, let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let received = buf.count - headEnd.upperBound
                if received >= cl {
                    self.dispatch(data: buf, conn: conn, transferID: tid)
                    return
                }
            }

            if isComplete {
                self.dispatch(data: buf, conn: conn, transferID: tid)
            } else {
                self.accumulate(conn: conn, buffer: buf, contentLength: cl, transferID: tid)
            }
        }
    }

    // MARK: - HTTP dispatch

    nonisolated private func dispatch(data: Data, conn: NWConnection, transferID: UUID?) {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else {
            send(conn: conn, status: 400, body: Data("Bad Request".utf8))
            return
        }
        let headStr = String(data: data[..<sep.lowerBound], encoding: .utf8) ?? ""
        let firstLine = headStr.components(separatedBy: "\r\n").first ?? ""
        let tokens = firstLine.components(separatedBy: " ")
        guard tokens.count >= 2 else { return }
        let method = tokens[0]
        let path = tokens[1].components(separatedBy: "?").first ?? tokens[1]

        switch (method, path) {
        case ("GET", "/"):
            send(conn: conn, status: 200, contentType: "text/html; charset=utf-8", body: Data(uploadPageHTML().utf8))
        case ("POST", "/upload"):
            handleUpload(headStr: headStr, body: Data(data[sep.upperBound...]), conn: conn, transferID: transferID)
        default:
            send(conn: conn, status: 404, body: Data("Not Found".utf8))
        }
    }

    // MARK: - Upload handling

    nonisolated private func handleUpload(headStr: String, body: Data, conn: NWConnection, transferID: UUID?) {
        // Extract multipart boundary from Content-Type header
        guard let ctLine = headStr.components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("content-type:") }),
              let bRange = ctLine.range(of: "boundary=") else {
            send(conn: conn, status: 400, body: Data("Missing boundary".utf8))
            return
        }
        let rawBoundary = String(ctLine[bRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        let boundary = Data(("--" + rawBoundary).utf8)

        var imported = 0
        var savedFiles: [(url: URL, name: String)] = []
        var searchFrom = body.startIndex

        while let bStart = body.range(of: boundary, in: searchFrom..<body.endIndex) {
            let afterBoundary = bStart.upperBound
            // Final boundary marker "--"
            if body[afterBoundary...].starts(with: Data("--".utf8)) { break }
            // Skip the \r\n after the boundary line
            let partStart = body.index(afterBoundary, offsetBy: 2, limitedBy: body.endIndex) ?? afterBoundary
            // Find where the next boundary begins
            guard let nextBound = body.range(of: boundary, in: partStart..<body.endIndex) else { break }
            // Part ends with \r\n right before the next boundary
            let partEnd = body.index(nextBound.lowerBound, offsetBy: -2, limitedBy: partStart) ?? nextBound.lowerBound
            let partData = body[partStart..<partEnd]

            if let (filename, fileData) = parsePart(Data(partData)), !fileData.isEmpty {
                if let dest = saveToDocs(data: fileData, filename: filename) {
                    savedFiles.append((url: dest, name: dest.lastPathComponent))
                }
                imported += 1
            }
            searchFrom = nextBound.lowerBound
        }

        if imported > 0 {
            // Build per-file info: (savedURL, displayName, actualBytes)
            let perFile: [(URL?, String, Int)] = savedFiles.map { (url, name) in
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return (url, name, bytes)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.importedCount += imported
                // Replace the single in-flight entry with one row per file
                if let tid = transferID {
                    self.activeTransfers.removeAll { $0.id == tid }
                }
                var newIDs: [UUID] = []
                for (url, name, bytes) in perFile {
                    let id = UUID()
                    newIDs.append(id)
                    self.activeTransfers.append(ActiveTransfer(id: id, displayName: name, totalBytes: bytes, progress: 1.0, savedURL: url))
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.activeTransfers.removeAll { newIDs.contains($0.id) }
            }
            let html = responseHTML("✓ Imported \(imported) file\(imported == 1 ? "" : "s"). <a href='/'>Upload more</a>", color: "#30d158")
            send(conn: conn, status: 200, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
        } else {
            Task { @MainActor [weak self] in
                guard let self, let tid = transferID else { return }
                self.activeTransfers.removeAll { $0.id == tid }
            }
            let html = responseHTML("✗ No supported files were received.", color: "#ff453a")
            send(conn: conn, status: 400, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
        }
    }

    nonisolated private func parsePart(_ data: Data) -> (String, Data)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerStr = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        guard headerStr.contains("filename=") else { return nil }
        var filename = "upload"
        if let fnRange = headerStr.range(of: "filename=\""),
           let fnEnd = headerStr[fnRange.upperBound...].range(of: "\"") {
            filename = String(headerStr[fnRange.upperBound..<fnEnd.lowerBound])
        }
        guard !filename.isEmpty, filename != "\"" else { return nil }
        return (filename, Data(data[headerEnd.upperBound...]))
    }

    @discardableResult
    nonisolated private func saveToDocs(data: Data, filename: String) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mpvFolder = docs.appendingPathComponent("MPV", isDirectory: true)
        try? FileManager.default.createDirectory(at: mpvFolder, withIntermediateDirectories: true)
        let base = URL(fileURLWithPath: filename)
        let candidate = mpvFolder.appendingPathComponent(filename)
        let dest = FileManager.default.fileExists(atPath: candidate.path)
            ? mpvFolder.appendingPathComponent(
                "\(base.deletingPathExtension().lastPathComponent)_\(Int(Date().timeIntervalSince1970)).\(base.pathExtension)")
            : candidate
        do {
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }

    // MARK: - HTTP helpers

    nonisolated private func send(conn: NWConnection, status: Int, contentType: String = "text/plain", body: Data) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default:  statusText = "Error"
        }
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let response = Data(header.utf8) + body
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    nonisolated private func responseHTML(_ message: String, color: String) -> String {
        "<html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        + "<style>body{font-family:-apple-system,sans-serif;background:#111;color:#eee;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;padding:24px}"
        + "p{font-size:18px;color:\(color)}</style></head><body><p>\(message)</p></body></html>"
    }

    // MARK: - Upload page HTML

    nonisolated private func uploadPageHTML() -> String {
        let ip = localIPAddress() ?? "your device"
        let port = _localPort
        let lines: [String] = [
            "<!DOCTYPE html><html>",
            "<head>",
            "<meta charset=\"utf-8\">",
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">",
            "<title>mpv \u{2013} WiFi Transfer</title>",
            "<style>",
            "*{box-sizing:border-box}",
            "body{margin:0;font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#111;color:#eee;display:flex;flex-direction:column;align-items:center;min-height:100vh;padding:24px;text-align:center}",
            "h1{font-size:22px;font-weight:600;margin:0 0 6px}",
            ".sub{color:#888;font-size:14px;margin:0 0 28px}",
            ".drop{border:2px dashed #444;border-radius:16px;padding:48px 32px;cursor:pointer;transition:border-color .2s,background .2s;width:100%;max-width:480px}",
            ".drop.over{border-color:#722A72;background:rgba(114,42,114,.1)}",
            ".drop-title{font-size:17px;margin:0 0 6px}",
            ".drop-hint{color:#666;font-size:13px;margin:0}",
            "input[type=file]{display:none}",
            "#queue{width:100%;max-width:480px;margin-top:16px}",
            ".item{display:flex;flex-direction:column;align-items:flex-start;background:#1c1c1e;border-radius:10px;padding:10px 14px;margin-bottom:8px;text-align:left}",
            ".item-name{font-size:14px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}",
            ".item-sub{font-size:12px;color:#888;margin-top:2px}",
            ".bar-track{width:100%;height:4px;background:#2c2c2e;border-radius:2px;margin-top:8px;overflow:hidden}",
            ".bar-fill{height:100%;width:0%;background:#722A72;border-radius:2px;transition:width .1s linear}",
            ".ok .bar-fill{background:#722A72}",
            ".err .bar-fill{background:#ff453a}",
            "</style></head>",
            "<body>",
            "<h1>WiFi Transfer</h1>",
            "<p class=\"sub\">\(ip):\(port)</p>",
            "<div class=\"drop\" id=\"drop\" onclick=\"document.getElementById('fi').click()\">",
            "<p class=\"drop-title\">Drop video or audio files here</p>",
            "<p class=\"drop-hint\">or tap to choose files</p>",
            "<input type=\"file\" id=\"fi\" accept=\"video/*,audio/*,.mkv,.flac,.opus,.ogg,.m4v,.webm\" multiple>",
            "</div>",
            "<div id=\"queue\"></div>",
            "<script>",
            "const drop=document.getElementById('drop');",
            "const queue=document.getElementById('queue');",
            "drop.addEventListener('dragover',e=>{e.preventDefault();drop.classList.add('over')});",
            "drop.addEventListener('dragleave',()=>drop.classList.remove('over'));",
            "drop.addEventListener('drop',e=>{e.preventDefault();drop.classList.remove('over');go(e.dataTransfer.files)});",
            "document.getElementById('fi').addEventListener('change',e=>{go(e.target.files);e.target.value='';});",
            "function fmt(b){if(b<1024)return b+'B';if(b<1048576)return(b/1024).toFixed(1)+'KB';return(b/1048576).toFixed(1)+'MB';}",
            "function go(files){",
            "  Array.from(files).forEach(f=>uploadOne(f));",
            "}",
            "function uploadOne(f){",
            "  const card=document.createElement('div');",
            "  card.className='item';",
            "  card.innerHTML='<div class=\"item-name\">'+f.name+'</div><div class=\"item-sub\">0 B of '+fmt(f.size)+'</div><div class=\"bar-track\"><div class=\"bar-fill\" id=\"bf_\"+encodeURIComponent(f.name)+Date.now()+Math.random().toString(36).slice(2)></div></div>';",
            "  queue.appendChild(card);",
            "  const fill=card.querySelector('.bar-fill');",
            "  const sub=card.querySelector('.item-sub');",
            "  const fd=new FormData();",
            "  fd.append('file',f);",
            "  const xhr=new XMLHttpRequest();",
            "  xhr.open('POST','/upload');",
            "  xhr.setRequestHeader('X-Filename',encodeURIComponent(f.name));",
            "  xhr.upload.onprogress=e=>{",
            "    if(!e.lengthComputable)return;",
            "    const pct=e.loaded/e.total*100;",
            "    fill.style.width=pct+'%';",
            "    sub.textContent=fmt(e.loaded)+' of '+fmt(f.size);",
            "  };",
            "  xhr.onload=()=>{",
            "    fill.style.width='100%';",
            "    sub.textContent=fmt(f.size);",
            "    card.classList.add('ok');",
            "    setTimeout(()=>{card.style.transition='opacity .4s';card.style.opacity='0';setTimeout(()=>card.remove(),400);},1000);",
            "  };",
            "  xhr.onerror=()=>{card.classList.add('err');sub.textContent='Failed';};",
            "  xhr.send(fd);",
            "}",
            "</script></body></html>"
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: - Local IP

    nonisolated func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let current = ptr {
            let iface = current.pointee
            if iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(iface.ifa_addr,
                                socklen_t(iface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
            ptr = current.pointee.ifa_next
        }
        return address
    }
}
