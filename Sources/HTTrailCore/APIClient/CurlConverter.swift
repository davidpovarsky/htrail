import Foundation

/// Imports a `curl` command into an ``APIRequest`` and exports the reverse —
/// the Hoppscotch "Import cURL" / "Generate code" feature.
public struct CurlConverter: Sendable {
    public init() {}

    // MARK: Import

    public func importCommand(_ command: String) -> APIRequest? {
        let tokens = tokenize(command)
        guard let curlIdx = tokens.firstIndex(where: { $0 == "curl" }) ?? (tokens.isEmpty ? nil : tokens.startIndex) else {
            return nil
        }
        var request = APIRequest(name: "Imported")
        var explicitMethod: String?
        var headers: [KeyValueItem] = []
        var dataParts: [String] = []
        var formFields: [BodyField] = []          // -F / --form
        var urlEncodedFields: [BodyField] = []    // --data-urlencode
        var queryParams: [KeyValueItem] = []
        var moveDataToQuery = false               // -G / --get
        var url: String?

        func consumeValue(from inline: String? = nil) -> String? {
            if let inline { return inline }
            let next = tokens.index(after: i)
            guard next < tokens.endIndex else { return nil }
            i = next
            return tokens[i]
        }

        func consumeShortValue(_ token: String) -> String? {
            if token.count > 2 { return String(token.dropFirst(2)) }
            return consumeValue()
        }

        func appendHeader(_ name: String, _ value: String) {
            headers.append(KeyValueItem(name: name, value: value))
        }

        func appendHeaderIfMissing(_ name: String, _ value: String) {
            guard !headers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
            appendHeader(name, value)
        }

        var i = tokens.index(after: curlIdx)
        while i < tokens.endIndex {
            let token = tokens[i]
            if token == "--" {
                if let value = consumeValue(), url == nil { url = value }
            } else if token.hasPrefix("--") {
                let (option, inlineValue) = splitLongOption(token)
                switch option {
                case "--request":
                    if let value = consumeValue(from: inlineValue) { explicitMethod = value.uppercased() }
                case "--header":
                    if let value = consumeValue(from: inlineValue), let pair = splitHeader(value) {
                        appendHeader(pair.0, pair.1)
                    }
                case "--data", "--data-raw", "--data-binary", "--data-ascii":
                    if let value = consumeValue(from: inlineValue) { dataParts.append(value) }
                case "--data-urlencode":
                    if let value = consumeValue(from: inlineValue) {
                        let (name, value) = splitFormPair(value)
                        urlEncodedFields.append(BodyField(name: name, value: value))
                    }
                case "--form", "--form-string":
                    if let value = consumeValue(from: inlineValue) {
                        appendFormField(value, to: &formFields)
                    }
                case "--user":
                    if let value = consumeValue(from: inlineValue) {
                        applyBasicAuth(value, to: &request)
                    }
                case "--user-agent":
                    if let value = consumeValue(from: inlineValue) { appendHeader("User-Agent", value) }
                case "--referer":
                    if let value = consumeValue(from: inlineValue) { appendHeader("Referer", value) }
                case "--cookie", "--cookie-raw":
                    if let value = consumeValue(from: inlineValue) { appendHeader("Cookie", value) }
                case "--oauth2-bearer":
                    if let value = consumeValue(from: inlineValue) {
                        var auth = AuthConfig(); auth.type = .bearer; auth.token = value
                        request.auth = auth
                    }
                case "--json":
                    if let value = consumeValue(from: inlineValue) {
                        dataParts.append(value)
                        appendHeaderIfMissing("Content-Type", "application/json")
                        appendHeaderIfMissing("Accept", "application/json")
                    }
                case "--url":
                    if let value = consumeValue(from: inlineValue) { url = value }
                case "--url-query":
                    if let value = consumeValue(from: inlineValue) {
                        queryParams.append(contentsOf: queryItems(from: value))
                    }
                case "--get":
                    moveDataToQuery = true
                case "--head":
                    explicitMethod = "HEAD"
                case "--next":
                    i = tokens.endIndex
                    continue
                default:
                    if Self.longOptionsWithValue.contains(option) {
                        _ = consumeValue(from: inlineValue)
                    } else if inlineValue == nil {
                        let next = tokens.index(after: i)
                        if next < tokens.endIndex,
                           !tokens[next].hasPrefix("-"),
                           !looksLikeURLCandidate(tokens[next]) {
                            _ = consumeValue()
                        }
                    }
                }
            } else if token.hasPrefix("-"), token != "-" {
                if token.hasPrefix("-X") {
                    if let value = consumeShortValue(token) { explicitMethod = value.uppercased() }
                } else if token.hasPrefix("-H") {
                    if let value = consumeShortValue(token), let pair = splitHeader(value) {
                        appendHeader(pair.0, pair.1)
                    }
                } else if token.hasPrefix("-d") {
                    if let value = consumeShortValue(token) { dataParts.append(value) }
                } else if token.hasPrefix("-F") {
                    if let value = consumeShortValue(token) {
                        appendFormField(value, to: &formFields)
                    }
                } else if token.hasPrefix("-u") {
                    if let value = consumeShortValue(token) {
                        applyBasicAuth(value, to: &request)
                    }
                } else if token.hasPrefix("-A") {
                    if let value = consumeShortValue(token) { appendHeader("User-Agent", value) }
                } else if token.hasPrefix("-e") {
                    if let value = consumeShortValue(token) { appendHeader("Referer", value) }
                } else if token.hasPrefix("-b") {
                    if let value = consumeShortValue(token) { appendHeader("Cookie", value) }
                } else if Self.shortOptionsWithValue.contains(String(token.dropFirst().prefix(1))) {
                    _ = consumeShortValue(token)
                } else {
                    let flags = token.dropFirst()
                    if flags.contains("G") { moveDataToQuery = true }
                    if flags.contains("I") { explicitMethod = "HEAD" }
                }
            } else if url == nil {
                if looksLikeURLCandidate(token) || !token.isEmpty {
                    url = token
                }
            }
            i = tokens.index(after: i)
        }

        if moveDataToQuery {
            queryParams.append(contentsOf: urlEncodedFields.map { KeyValueItem(name: $0.name, value: $0.value) })
            for part in dataParts {
                queryParams.append(contentsOf: queryItems(from: part))
            }
            urlEncodedFields.removeAll()
            dataParts.removeAll()
        }

        guard let finalURL = url else { return nil }
        let urlParts = splitURLQuery(finalURL)
        request.url = urlParts.url
        request.headers = headers
        request.queryParams = urlParts.queryParams + queryParams
        let hasBody = !dataParts.isEmpty || !formFields.isEmpty || !urlEncodedFields.isEmpty
        if !formFields.isEmpty {
            // `-F`/`--form` is normally multipart, but exporters (and people) also
            // pair it with an explicit `Content-Type: application/x-www-form-urlencoded`
            // header. Honor that header so the body is urlencoded, not multipart —
            // otherwise the boundary header is suppressed and the request is malformed.
            let contentType = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?
                .value.lowercased() ?? ""
            request.bodyMode = contentType.contains("application/x-www-form-urlencoded") ? .formURLEncoded : .multipart
            request.bodyForm = formFields
        } else if !urlEncodedFields.isEmpty {
            request.bodyMode = .formURLEncoded
            request.bodyForm = urlEncodedFields
        } else if !dataParts.isEmpty {
            request.rawBody = dataParts.joined(separator: "&")
            request.bodyMode = looksLikeJSON(request.rawBody) ? .json : .raw
        }
        request.method = explicitMethod ?? (hasBody ? "POST" : "GET")
        return request
    }

    // MARK: Export

    public func exportCommand(_ request: APIRequest, environment: [String: String] = [:]) -> String {
        var parts = ["curl"]
        if request.method != "GET" { parts.append("-X \(request.method)") }

        var urlString = request.url
        let activeQuery = request.queryParams.filter { $0.enabled && !$0.name.isEmpty }
        if !activeQuery.isEmpty, var comps = URLComponents(string: urlString) {
            var items = comps.queryItems ?? []
            items.append(contentsOf: activeQuery.map { URLQueryItem(name: $0.name, value: $0.value) })
            comps.queryItems = items
            urlString = comps.url?.absoluteString ?? urlString
        }
        parts.append("'\(urlString)'")

        for header in request.headers where header.enabled && !header.name.isEmpty {
            parts.append("-H '\(header.name): \(header.value)'")
        }
        switch request.auth.type {
        case .bearer: parts.append("-H 'Authorization: Bearer \(request.auth.token)'")
        case .basic: parts.append("-u '\(request.auth.username):\(request.auth.password)'")
        case .apiKey where request.auth.addToHeader:
            parts.append("-H '\(request.auth.key): \(request.auth.value)'")
        default: break
        }
        switch request.bodyMode {
        case .multipart where BodyEncoder.hasFields(request.bodyForm):
            for field in request.bodyForm where field.enabled && !field.name.isEmpty {
                if field.isFile {
                    let filename = field.fileName.isEmpty ? "file" : field.fileName
                    parts.append("-F '\(shellEscape(field.name))=@\(shellEscape(filename))'")
                } else {
                    parts.append("-F '\(shellEscape(field.name))=\(shellEscape(field.value))'")
                }
            }
        case .formURLEncoded where BodyEncoder.hasFields(request.bodyForm):
            parts.append("--data '\(shellEscape(BodyEncoder.urlEncoded(request.bodyForm)))'")
        default:
            if request.bodyMode != .none, !request.rawBody.isEmpty {
                parts.append("--data '\(shellEscape(request.rawBody))'")
            }
        }
        return parts.joined(separator: " \\\n  ")
    }

    // MARK: Helpers

    private static let longOptionsWithValue: Set<String> = {
        [
            "--abstract-unix-socket", "--alt-svc", "--aws-sigv4", "--cacert", "--capath",
            "--cert", "--cert-type", "--ciphers", "--connect-timeout", "--connect-to",
            "--config", "--cookie-jar", "--curves", "--dns-interface", "--dns-ipv4-addr",
            "--dns-ipv6-addr", "--doh-url", "--dump-header", "--engine", "--etag-compare",
            "--etag-save", "--expect100-timeout", "--ftp-account", "--ftp-alternative-to-user",
            "--ftp-method", "--ftp-port", "--ftp-ssl-ccc-mode", "--haproxy-clientip",
            "--hostpubmd5", "--hostpubsha256", "--interface", "--ip-tos", "--key",
            "--key-type", "--krb", "--limit-rate", "--local-port", "--login-options",
            "--mail-auth", "--mail-from", "--mail-rcpt", "--max-filesize", "--max-redirs",
            "--max-time", "--netrc-file", "--output", "--output-dir", "--pass",
            "--pinnedpubkey", "--preproxy", "--proto", "--proto-default", "--proto-redir",
            "--proxy", "--proxy-cacert", "--proxy-capath", "--proxy-cert", "--proxy-cert-type",
            "--proxy-ciphers", "--proxy-header", "--proxy-key", "--proxy-key-type",
            "--proxy-pass", "--proxy-pinnedpubkey", "--proxy-service-name", "--proxy-tls13-ciphers",
            "--proxy-tlsauthtype", "--proxy-tlspassword", "--proxy-tlsuser", "--proxy-user",
            "--proxy1.0", "--pubkey", "--quote", "--random-file", "--range", "--rate",
            "--request-target", "--resolve", "--retry", "--retry-delay", "--retry-max-time",
            "--service-name", "--socks4", "--socks4a", "--socks5", "--socks5-gssapi-service",
            "--socks5-hostname", "--speed-limit", "--speed-time", "--stderr", "--telnet-option",
            "--tftp-blksize", "--time-cond", "--tls-max", "--tls13-ciphers", "--tlspassword",
            "--tlsuser", "--tlsauthtype", "--unix-socket", "--upload-file", "--variable",
            "--write-out"
        ]
    }()

    private static let shortOptionsWithValue: Set<String> = {
        ["c", "C", "D", "E", "K", "m", "o", "P", "Q", "r", "T", "U", "w", "x", "y", "Y", "z"]
    }()

    private func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func splitLongOption(_ raw: String) -> (String, String?) {
        guard let eq = raw.firstIndex(of: "=") else { return (raw, nil) }
        return (String(raw[..<eq]), String(raw[raw.index(after: eq)...]))
    }

    /// Splits a `name=value` form token on the first `=`.
    private func splitFormPair(_ raw: String) -> (String, String) {
        guard let eq = raw.firstIndex(of: "=") else { return (raw, "") }
        return (String(raw[..<eq]), String(raw[raw.index(after: eq)...]))
    }

    private func queryItems(from raw: String) -> [KeyValueItem] {
        raw.split(separator: "&", omittingEmptySubsequences: false).map { part in
            let (name, value) = splitFormPair(String(part))
            return KeyValueItem(name: percentDecoded(name), value: percentDecoded(value))
        }.filter { !$0.name.isEmpty }
    }

    private func splitURLQuery(_ raw: String) -> (url: String, queryParams: [KeyValueItem]) {
        guard let question = raw.firstIndex(of: "?") else {
            return (raw, [])
        }

        let base = String(raw[..<question])
        let remainder = raw[raw.index(after: question)...]
        let query: String
        let suffix: String
        if let fragment = remainder.firstIndex(of: "#") {
            query = String(remainder[..<fragment])
            suffix = String(remainder[fragment...])
        } else {
            query = String(remainder)
            suffix = ""
        }

        return (base + suffix, queryItems(from: query))
    }

    private func percentDecoded(_ raw: String) -> String {
        let bytes = Array(raw.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 43 { // "+"
                output.append(32)
                index += 1
            } else if byte == 37, // "%"
                      index + 2 < bytes.count,
                      let hi = hexValue(bytes[index + 1]),
                      let lo = hexValue(bytes[index + 2]) {
                output.append(hi << 4 | lo)
                index += 3
            } else {
                output.append(byte)
                index += 1
            }
        }

        return String(decoding: output, as: UTF8.self)
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48       // 0...9
        case 65...70: byte - 55       // A...F
        case 97...102: byte - 87      // a...f
        default: nil
        }
    }

    private func appendFormField(_ raw: String, to fields: inout [BodyField]) {
        let (rawName, rawValue) = splitFormPair(raw)
        let name = unwrapQuotes(rawName)
        if rawValue.hasPrefix("@") || rawValue.hasPrefix("<") {
            fields.append(BodyField(name: name, isFile: true,
                                    fileName: unwrapQuotes(String(rawValue.dropFirst()))))
        } else {
            fields.append(BodyField(name: name, value: unwrapQuotes(rawValue)))
        }
    }

    private func applyBasicAuth(_ raw: String, to request: inout APIRequest) {
        let creds = raw.split(separator: ":", maxSplits: 1)
        var auth = AuthConfig(); auth.type = .basic
        auth.username = String(creds.first ?? "")
        auth.password = creds.count > 1 ? String(creds[1]) : ""
        request.auth = auth
    }

    /// curl's `-F`/`--form` lets the field name, content, or file name be wrapped
    /// in double quotes to protect special characters; the quotes are not part of
    /// the value. Many exporters (Postman, Insomnia) always quote — e.g.
    /// `--form 'msisdn="0819188052"'` — so strip a matched surrounding pair.
    private func unwrapQuotes(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    private func splitHeader(_ raw: String) -> (String, String)? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let name = raw[..<colon].trimmingCharacters(in: .whitespaces)
        let value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (name, value)
    }

    private func looksLikeJSON(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    private func looksLikeURLCandidate(_ token: String) -> Bool {
        let lower = token.lowercased()
        return lower.contains("://")
            || lower.hasPrefix("localhost")
            || lower.hasPrefix("www.")
            || lower.contains(".")
            || lower.hasPrefix("[")
    }

    /// Shell-like tokenizer that respects the quoting/escaping conventions of the
    /// shells people actually copy `curl` from — bash, zsh, sh, cmd.exe and
    /// PowerShell — so a pasted command imports a clean body regardless of source:
    ///
    /// - bash/zsh/sh single quotes `'…'`: fully literal; a literal apostrophe is
    ///   spliced in via the `'\''` idiom (close, escaped quote, reopen).
    /// - bash/cmd double quotes `"…"`: backslash escapes `" \ $ \``; e.g. cmd's
    ///   `--data "{\"a\":1}"`.
    /// - Doubled quotes inside a quoted run (`''` → `'`, `""` → `"`): the
    ///   PowerShell / cmd / SQL way to embed the quote char without closing.
    /// - PowerShell backtick escapes inside double quotes (`` `" `` → `"`,
    ///   `` `$ `` → `$`, `` `n `` → newline …) and `\` / `` ` `` line continuations.
    private func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var iterator = command.makeIterator()
        var pending: Character?

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        func peekChar() -> Character? {
            if pending == nil { pending = iterator.next() }
            return pending
        }

        while let ch = nextChar() {
            if let q = quote {
                if ch == q {
                    // A doubled quote inside the run is an escaped literal quote
                    // (PowerShell/cmd/SQL: '' -> ', "" -> ") — consume both and
                    // stay in the string instead of closing it.
                    if peekChar() == q {
                        _ = nextChar()
                        current.append(q)
                    } else {
                        quote = nil
                    }
                } else if q == "\"", ch == "\\" {
                    // Inside double quotes a backslash escapes only " \ $ ` (and a
                    // line-continuation newline); otherwise it's literal. Without
                    // this, cmd's `--data "{\"a\":1}"` kept stray backslashes and
                    // the inner quote closed the token early.
                    if let next = nextChar() {
                        switch next {
                        case "\"", "\\", "$", "`": current.append(next)
                        case "\n", "\r": break  // line continuation
                        default: current.append("\\"); current.append(next)
                        }
                    } else {
                        current.append("\\")
                    }
                } else if q == "\"", ch == "`" {
                    // PowerShell backtick escapes inside double quotes. Only the
                    // known sequences are translated; anything else keeps the
                    // backtick literal so it round-trips.
                    if let next = nextChar() {
                        switch next {
                        case "\"", "$", "`": current.append(next)
                        case "n": current.append("\n")
                        case "t": current.append("\t")
                        case "r": current.append("\r")
                        case "\n", "\r": break  // line continuation
                        default: current.append("`"); current.append(next)
                        }
                    } else {
                        current.append("`")
                    }
                } else {
                    current.append(ch)
                }
            } else {
                switch ch {
                case "'", "\"":
                    quote = ch
                case "\\", "`":
                    // Line continuation (`\`/`` ` `` + newline) or an escaped char.
                    if let next = nextChar(), next != "\n", next != "\r" {
                        current.append(next)
                    }
                case " ", "\t", "\n", "\r":
                    if !current.isEmpty { tokens.append(current); current = "" }
                default:
                    current.append(ch)
                }
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
