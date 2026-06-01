import Foundation

enum WebTools {

    fileprivate struct SearchResult {
        let title: String
        let url: String
        let snippet: String
        let source: String
        let publishedAt: String?

        var dictionary: [String: Any] {
            var value: [String: Any] = [
                "title": title,
                "url": url,
                "snippet": snippet,
                "source": source
            ]
            if let publishedAt, !publishedAt.isEmpty {
                value["published_at"] = publishedAt
            }
            return value
        }
    }

    private enum WebToolError: LocalizedError {
        case invalidURL
        case unsupportedURLScheme
        case httpStatus(Int)
        case blocked(String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return tr("URL 无效", "Invalid URL")
            case .unsupportedURLScheme:
                return tr("只支持 http/https URL", "Only http/https URLs are supported")
            case .httpStatus(let status):
                return tr("HTTP \(status)", "HTTP \(status)")
            case .blocked(let provider):
                return tr("\(provider) 暂时拒绝了自动搜索请求", "\(provider) temporarily blocked automated search")
            case .emptyResponse:
                return tr("网页没有返回可读取内容", "The page returned no readable content")
            }
        }
    }

    static func register(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "web-search",
            description: tr(
                "免费联网搜索实时网页信息；无需 API key，默认使用公开搜索结果页，失败时会自动尝试备用来源",
                "Search the live web for current information for free; no API key required, using public search result pages with fallback sources"
            ),
            parameters: tr(
                "query: 搜索关键词, max_results: 返回结果数（可选，默认 5，最多 8）",
                "query: search query, max_results: number of results (optional, default 5, max 8)"
            ),
            requiredParameters: ["query"],
            aliases: ["web_search", "search-web", "search_web"],
            execute: { args in
                await searchCanonical(args).detail
            },
            executeCanonical: { args in
                await searchCanonical(args)
            }
        ))

        registry.register(RegisteredTool(
            name: "web-fetch",
            description: tr(
                "读取公开网页正文并转换成适合模型使用的纯文本摘要",
                "Fetch a public webpage and convert the readable body to plain text for the model"
            ),
            parameters: tr(
                "url: 要读取的网页 URL, max_characters: 最大返回字符数（可选，默认 6000，最多 12000）",
                "url: webpage URL to read, max_characters: maximum returned characters (optional, default 6000, max 12000)"
            ),
            requiredParameters: ["url"],
            aliases: ["web_fetch", "fetch-web", "fetch_web", "read-url"],
            execute: { args in
                await fetchCanonical(args).detail
            },
            executeCanonical: { args in
                await fetchCanonical(args)
            }
        ))
    }

    // MARK: - Tool Entry Points

    private static func searchCanonical(_ args: [String: Any]) async -> CanonicalToolResult {
        let query = stringArgument(args["query"])
        guard !query.isEmpty else {
            return webFailure(
                summary: tr("要搜索什么?", "What should I search for?"),
                detail: tr("缺少 query 参数", "Missing query parameter"),
                errorCode: "WEB_SEARCH_QUERY_MISSING"
            )
        }

        let maxResults = clampedInt(args["max_results"], defaultValue: 5, minValue: 1, maxValue: 8)
        let fetchedAt = iso8601String(from: Date())
        let isNewsQuery = isNewsLikeQuery(query)
        let providerQuery = normalizedSearchQuery(query, isNewsQuery: isNewsQuery)
        var providerErrors: [String] = []

        let providers: [(String, (String, Int) async throws -> [SearchResult])] = isNewsQuery
            ? [
                ("bing-news-rss", searchBingNewsRSS),
                ("duckduckgo-html", searchDuckDuckGo),
                ("bing-rss", searchBingRSS)
            ]
            : [
                ("duckduckgo-html", searchDuckDuckGo),
                ("bing-rss", searchBingRSS)
            ]

        for (providerName, provider) in providers {
            do {
                let results = uniqueResults(try await provider(providerQuery, maxResults))
                    .prefix(maxResults)
                    .map { $0 }
                if !results.isEmpty {
                    return searchSuccess(
                        query: providerQuery,
                        fetchedAt: fetchedAt,
                        provider: providerName,
                        results: results,
                        providerErrors: providerErrors,
                        isNewsQuery: isNewsQuery
                    )
                }
                providerErrors.append("\(providerName): empty")
            } catch {
                providerErrors.append("\(providerName): \(error.localizedDescription)")
            }
        }

        let summary = tr(
            "没有找到可用的实时搜索结果。免费搜索来源可能暂时限流或没有匹配内容。",
            "No live search results were available. Free search sources may be rate-limited or have no matching content."
        )
        let detail = successPayload(
            result: summary,
            extras: [
                "query": providerQuery,
                "original_query": query,
                "fetched_at": fetchedAt,
                "provider": "none",
                "provider_errors": providerErrors,
                "results": []
            ]
        )
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
    }

    private static func fetchCanonical(_ args: [String: Any]) async -> CanonicalToolResult {
        let rawURL = stringArgument(args["url"])
        guard !rawURL.isEmpty else {
            return webFailure(
                summary: tr("要读取哪个链接?", "Which URL should I read?"),
                detail: tr("缺少 url 参数", "Missing url parameter"),
                errorCode: "WEB_FETCH_URL_MISSING"
            )
        }

        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return webFailure(
                summary: tr("这个链接格式不对。", "That URL is not valid."),
                detail: tr("URL 无效: \(rawURL)", "Invalid URL: \(rawURL)"),
                errorCode: "WEB_FETCH_INVALID_URL"
            )
        }

        guard ["http", "https"].contains((url.scheme ?? "").lowercased()) else {
            return webFailure(
                summary: tr("只支持读取 http/https 网页。", "Only http/https webpages are supported."),
                detail: tr("不支持的 URL scheme: \(url.scheme ?? "")", "Unsupported URL scheme: \(url.scheme ?? "")"),
                errorCode: "WEB_FETCH_UNSUPPORTED_SCHEME"
            )
        }

        let maxCharacters = clampedInt(args["max_characters"], defaultValue: 6000, minValue: 500, maxValue: 12_000)

        do {
            let fetched = try await fetchReadablePage(url: url, maxCharacters: maxCharacters)
            let summary = formattedFetchSummary(
                title: fetched.title,
                url: fetched.finalURL,
                content: fetched.content,
                truncated: fetched.truncated
            )
            let detail = successPayload(
                result: summary,
                extras: [
                    "url": fetched.finalURL,
                    "title": fetched.title,
                    "content": fetched.content,
                    "truncated": fetched.truncated,
                    "fetched_at": iso8601String(from: Date())
                ]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)
        } catch {
            return webFailure(
                summary: tr(
                    "网页读取失败：\(error.localizedDescription)",
                    "Webpage fetch failed: \(error.localizedDescription)"
                ),
                detail: error.localizedDescription,
                errorCode: "WEB_FETCH_FAILED"
            )
        }
    }

    // MARK: - Search Providers

    private static func searchDuckDuckGo(query: String, maxResults: Int) async throws -> [SearchResult] {
        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else {
            throw WebToolError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query)
        ]
        guard let url = components.url else { throw WebToolError.invalidURL }

        let html = try await fetchText(url: url, accept: "text/html")
        if html.contains("anomaly-modal") || html.contains("Unfortunately, bots use DuckDuckGo too") {
            throw WebToolError.blocked("DuckDuckGo")
        }

        var results = parseDuckDuckGoResultAnchors(html, maxResults: maxResults)
        if results.isEmpty {
            results = parseDuckDuckGoLiteAnchors(html, maxResults: maxResults)
        }
        return results
    }

    private static func searchBingRSS(query: String, maxResults: Int) async throws -> [SearchResult] {
        guard var components = URLComponents(string: "https://www.bing.com/search") else {
            throw WebToolError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "format", value: "rss"),
            URLQueryItem(name: "setlang", value: LanguageService.shared.current.isChinese ? "zh-CN" : "en-US"),
            URLQueryItem(name: "cc", value: LanguageService.shared.current.isChinese ? "CN" : "US"),
            URLQueryItem(name: "q", value: query)
        ]
        guard let url = components.url else { throw WebToolError.invalidURL }

        let data = try await fetchData(url: url, accept: "application/rss+xml, application/xml, text/xml")
        let parser = BingRSSParser(source: "bing-rss")
        let results = parser.parse(data: data)
        return Array(results.prefix(maxResults))
    }

    private static func searchBingNewsRSS(query: String, maxResults: Int) async throws -> [SearchResult] {
        guard var components = URLComponents(string: "https://www.bing.com/news/search") else {
            throw WebToolError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "format", value: "rss"),
            URLQueryItem(name: "setlang", value: LanguageService.shared.current.isChinese ? "zh-CN" : "en-US"),
            URLQueryItem(name: "cc", value: LanguageService.shared.current.isChinese ? "CN" : "US"),
            URLQueryItem(name: "q", value: newsSearchQuery(query))
        ]
        guard let url = components.url else { throw WebToolError.invalidURL }

        let data = try await fetchData(url: url, accept: "application/rss+xml, application/xml, text/xml")
        let parser = BingRSSParser(source: "bing-news-rss")
        let results = parser.parse(data: data)
        return Array(results.prefix(maxResults))
    }

    // MARK: - Fetch

    private static func fetchReadablePage(
        url: URL,
        maxCharacters: Int
    ) async throws -> (title: String, finalURL: String, content: String, truncated: Bool) {
        let data = try await fetchData(url: url, accept: "text/html, text/plain, application/xhtml+xml")
        let limitedData = data.count > 2_000_000 ? Data(data.prefix(2_000_000)) : data
        let html = String(decoding: limitedData, as: UTF8.self)
        let title = extractTitle(from: html)
        let body = readableText(from: html)
        guard !body.isEmpty else { throw WebToolError.emptyResponse }

        let clipped = clippedText(body, maxCharacters: maxCharacters)
        return (
            title: title.isEmpty ? url.host ?? url.absoluteString : title,
            finalURL: url.absoluteString,
            content: clipped.text,
            truncated: clipped.truncated || data.count > limitedData.count
        )
    }

    private static func fetchData(url: URL, accept: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(acceptLanguageHeader(), forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200...299).contains(http.statusCode) else {
            throw WebToolError.httpStatus(http.statusCode)
        }
        return data
    }

    private static func fetchText(url: URL, accept: String) async throws -> String {
        let data = try await fetchData(url: url, accept: accept)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Parsing

    private static func parseDuckDuckGoResultAnchors(_ html: String, maxResults: Int) -> [SearchResult] {
        let matches = regexMatches(
            pattern: #"<a[^>]+class=["'][^"']*result__a[^"']*["'][^>]+href=["']([^"']+)["'][^>]*>(.*?)</a>"#,
            in: html,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        return parseAnchorMatches(matches, html: html, source: "duckduckgo", maxResults: maxResults)
    }

    private static func parseDuckDuckGoLiteAnchors(_ html: String, maxResults: Int) -> [SearchResult] {
        let matches = regexMatches(
            pattern: #"<a[^>]+href=["']([^"']+)["'][^>]*>(.*?)</a>"#,
            in: html,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ).filter { match in
            guard let href = capture(1, from: match, in: html) else { return false }
            return href.contains("duckduckgo.com/l/?") || href.contains("/l/?uddg=")
        }
        return parseAnchorMatches(matches, html: html, source: "duckduckgo", maxResults: maxResults)
    }

    private static func parseAnchorMatches(
        _ matches: [NSTextCheckingResult],
        html: String,
        source: String,
        maxResults: Int
    ) -> [SearchResult] {
        var results: [SearchResult] = []

        for (index, match) in matches.enumerated() {
            guard let rawHref = capture(1, from: match, in: html),
                  let titleHTML = capture(2, from: match, in: html),
                  let url = normalizeSearchResultURL(rawHref) else {
                continue
            }

            let title = stripHTML(titleHTML)
            guard !title.isEmpty else { continue }

            let matchEnd = NSMaxRange(match.range)
            let nextStart = index + 1 < matches.count
                ? matches[index + 1].range.location
                : min(html.utf16.count, match.range.location + 3000)
            let snippetHTML = substring(
                html,
                nsRange: NSRange(
                    location: matchEnd,
                    length: max(0, nextStart - matchEnd)
                )
            )
            let snippet = extractSnippet(from: snippetHTML)

            results.append(SearchResult(
                title: title,
                url: url,
                snippet: snippet,
                source: source,
                publishedAt: nil
            ))

            if results.count >= maxResults { break }
        }

        return uniqueResults(results)
    }

    private static func extractSnippet(from html: String) -> String {
        let patterns = [
            #"<a[^>]+class=["'][^"']*result__snippet[^"']*["'][^>]*>(.*?)</a>"#,
            #"<div[^>]+class=["'][^"']*result__snippet[^"']*["'][^>]*>(.*?)</div>"#,
            #"<td[^>]+class=["'][^"']*result-snippet[^"']*["'][^>]*>(.*?)</td>"#,
            #"<span[^>]+class=["'][^"']*result__snippet[^"']*["'][^>]*>(.*?)</span>"#
        ]
        for pattern in patterns {
            if let raw = firstCapture(pattern: pattern, in: html) {
                let value = stripHTML(raw)
                if !value.isEmpty { return value }
            }
        }
        return ""
    }

    private static func readableText(from html: String) -> String {
        var text = html
        let removalPatterns = [
            #"(?is)<script\b[^>]*>.*?</script>"#,
            #"(?is)<style\b[^>]*>.*?</style>"#,
            #"(?is)<svg\b[^>]*>.*?</svg>"#,
            #"(?is)<noscript\b[^>]*>.*?</noscript>"#,
            #"(?is)<head\b[^>]*>.*?</head>"#,
            #"(?is)<!--.*?-->"#
        ]
        for pattern in removalPatterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</(p|div|li|h[1-6]|section|article|tr)>"#, with: "\n", options: .regularExpression)
        return stripHTML(text)
    }

    private static func extractTitle(from html: String) -> String {
        guard let title = firstCapture(
            pattern: #"(?is)<title[^>]*>(.*?)</title>"#,
            in: html
        ) else {
            return ""
        }
        return stripHTML(title)
    }

    fileprivate static func stripHTML(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        return normalizeWhitespace(htmlDecode(noTags))
    }

    private static func htmlDecode(_ text: String) -> String {
        var decoded = text
        let named: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&nbsp;": " "
        ]
        for (entity, value) in named {
            decoded = decoded.replacingOccurrences(of: entity, with: value)
        }

        guard let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) else {
            return decoded
        }
        let matches = regex.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: decoded),
                  let valueRange = Range(match.range(at: 1), in: decoded) else {
                continue
            }
            let raw = String(decoded[valueRange])
            let radix = raw.lowercased().hasPrefix("x") ? 16 : 10
            let numberText = radix == 16 ? String(raw.dropFirst()) : raw
            guard let value = UInt32(numberText, radix: radix),
                  let scalar = UnicodeScalar(value) else {
                continue
            }
            decoded.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return decoded
    }

    // MARK: - Formatting

    private static func searchSuccess(
        query: String,
        fetchedAt: String,
        provider: String,
        results: [SearchResult],
        providerErrors: [String],
        isNewsQuery: Bool
    ) -> CanonicalToolResult {
        let sourceEntryFlags = results.map { isLikelySourceEntry($0) }
        let unconfirmedFlags = results.map { isLikelyUnconfirmedEntry($0) }
        let exactTerms = exactQueryTerms(query)
        let exactMatchFlags = results.map { exactTerms.isEmpty || resultMatchesExactTerms($0, exactTerms: exactTerms) }
        let hasExactMatches = exactMatchFlags.contains(true)
        let filteredPairs = results.enumerated().filter { index, _ in
            !(isNewsQuery && !exactTerms.isEmpty && hasExactMatches && !exactMatchFlags[index])
        }
        let resultPairs = filteredPairs.isEmpty ? Array(results.enumerated()) : filteredPairs
        let onlySourceEntries = isNewsQuery && !resultPairs.isEmpty && resultPairs.allSatisfy { index, _ in sourceEntryFlags[index] }
        let hasUnconfirmedVisibleResult = resultPairs.contains { index, _ in unconfirmedFlags[index] }
        let resultLines = resultPairs.map { index, item in
            let title = clippedText(item.title, maxCharacters: 100).text
            var labels: [String] = []
            if isNewsQuery && sourceEntryFlags[index] {
                labels.append(tr("可查看来源", "source to check"))
            }
            if isNewsQuery && unconfirmedFlags[index] {
                labels.append(tr("未确认/传闻", "unconfirmed/rumor"))
            }
            if isNewsQuery && !exactTerms.isEmpty && !resultMatchesExactTerms(item, exactTerms: exactTerms) {
                labels.append(tr("相关但非精确匹配", "related, not exact match"))
            }
            let labelPrefix = labels.isEmpty
                ? ""
                : labels.map { "[\($0)]" }.joined() + " "
            let exactMismatch = isNewsQuery && !exactTerms.isEmpty && !resultMatchesExactTerms(item, exactTerms: exactTerms)
            let shouldHideSnippet = isNewsQuery && (sourceEntryFlags[index] || exactMismatch)
            let snippet = shouldHideSnippet ? "" : clippedText(item.snippet, maxCharacters: 180).text
            let snippetPart = snippet.isEmpty ? "" : "\n   \(snippet)"
            let datePart = (item.publishedAt ?? "").isEmpty ? "" : "\n   \(tr("时间", "Date")): \(item.publishedAt!)"
            return "\(index + 1). \(labelPrefix)\(title)\n   \(tr("来源URL", "Source URL")): \(item.url)\(datePart)\(snippetPart)"
        }.joined(separator: "\n")

        let summary: String
        if onlySourceEntries {
            summary = tr(
                "实时搜索「\(query)」没有返回明确可核验的最新新闻条目（来源: \(provider)，搜索时间: \(fetchedAt)）。以下结果主要是首页、频道页或站点简介，只能当作可查看来源，不能总结成最新新闻事实：\n\(resultLines)",
                "Live search for \"\(query)\" did not return clearly verifiable latest news items (source: \(provider), fetched at: \(fetchedAt)). The results below are mostly homepages, category pages, or site descriptions; treat them only as sources to check, not as latest news facts:\n\(resultLines)"
            )
        } else if isNewsQuery && hasUnconfirmedVisibleResult {
            summary = tr(
                "实时搜索「\(query)」找到 \(resultPairs.count) 条可用结果（来源: \(provider)，搜索时间: \(fetchedAt)）。注意：带有[未确认/传闻]的条目不是官方确认；回答第一句应说明未找到官方确认或仅有未确认传闻，每条必须保留来源 URL；只能表述为“搜索结果显示有传闻/报道”，不能说成已经发布或确定会发布。带有[相关但非精确匹配]的条目不能当作用户所问对象的消息。首页、频道页或站点简介也不能当作最新新闻事实。\n\(resultLines)",
                "Live search for \"\(query)\" found \(resultPairs.count) usable result(s) (source: \(provider), fetched at: \(fetchedAt)). Note: entries labeled [unconfirmed/rumor] are not official confirmation; the first sentence should say no official confirmation was found or only unconfirmed rumors were found, and every item must keep its source URL. Describe them only as rumors/reports from search results, not as released or certain. Entries labeled [related, not exact match] must not be treated as news about the object the user asked for. Homepages, category pages, or site descriptions are also not latest news facts.\n\(resultLines)"
            )
        } else {
            summary = tr(
                "实时搜索「\(query)」找到 \(resultPairs.count) 条结果（来源: \(provider)，搜索时间: \(fetchedAt)）：\n注意：以下是搜索结果条目，不等于已核实结论；首页、频道页或站点简介只能当作可查看来源，不能当作最新新闻事实。\n\(resultLines)",
                "Live search for \"\(query)\" found \(resultPairs.count) result(s) (source: \(provider), fetched at: \(fetchedAt)):\nNote: these are search result entries, not verified conclusions; homepages, category pages, or site descriptions are only possible sources, not latest news facts.\n\(resultLines)"
            )
        }
        var extras: [String: Any] = [
            "query": query,
            "fetched_at": fetchedAt,
            "provider": provider,
            "results": results.map(\.dictionary)
        ]
        if !providerErrors.isEmpty {
            extras["provider_errors"] = providerErrors
        }
        let detail = successPayload(result: summary, extras: extras)
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
    }

    private static func formattedFetchSummary(
        title: String,
        url: String,
        content: String,
        truncated: Bool
    ) -> String {
        let suffix = truncated
            ? tr("\n\n（内容较长，已截断。）", "\n\n(Content is long; truncated.)")
            : ""
        return tr(
            "已读取网页：\(title)\n来源：\(url)\n\n\(content)\(suffix)",
            "Fetched webpage: \(title)\nSource: \(url)\n\n\(content)\(suffix)"
        )
    }

    private static func webFailure(summary: String, detail: String, errorCode: String) -> CanonicalToolResult {
        let payload = failurePayload(
            error: detail,
            extras: ["error_code": errorCode]
        )
        return CanonicalToolResult(
            success: false,
            summary: summary,
            detail: payload,
            errorCode: errorCode
        )
    }

    // MARK: - Utilities

    private static func stringArgument(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func clampedInt(_ value: Any?, defaultValue: Int, minValue: Int, maxValue: Int) -> Int {
        let raw: Int
        if let intValue = value as? Int {
            raw = intValue
        } else if let doubleValue = value as? Double {
            raw = Int(doubleValue)
        } else if let stringValue = value as? String, let intValue = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            raw = intValue
        } else {
            raw = defaultValue
        }
        return min(max(raw, minValue), maxValue)
    }

    private static func normalizeSearchResultURL(_ rawHref: String) -> String? {
        var href = htmlDecode(rawHref).trimmingCharacters(in: .whitespacesAndNewlines)
        if href.hasPrefix("//") {
            href = "https:" + href
        } else if href.hasPrefix("/") {
            href = "https://duckduckgo.com" + href
        }

        guard let url = URL(string: href) else { return nil }
        if url.host?.contains("duckduckgo.com") == true,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let unwrapped = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           !unwrapped.isEmpty {
            return unwrapped
        }

        guard ["http", "https"].contains((url.scheme ?? "").lowercased()) else { return nil }
        return url.absoluteString
    }

    private static func uniqueResults(_ results: [SearchResult]) -> [SearchResult] {
        var seen = Set<String>()
        var output: [SearchResult] = []
        for result in results {
            let key = result.url.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(result)
        }
        return output
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t\f\v]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clippedText(_ text: String, maxCharacters: Int) -> (text: String, truncated: Bool) {
        guard text.count > maxCharacters else {
            return (text, false)
        }
        let end = text.index(text.startIndex, offsetBy: maxCharacters)
        return (String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    private static func acceptLanguageHeader() -> String {
        LanguageService.shared.current.isChinese
            ? "zh-CN,zh;q=0.9,en;q=0.8"
            : "en-US,en;q=0.9"
    }

    private static func isNewsLikeQuery(_ query: String) -> Bool {
        let lower = query.lowercased()
        let markers = [
            "新闻", "最新", "今天", "今日", "消息", "发布", "宣布", "动态", "快讯", "最近", "近况",
            "news", "latest", "current", "today", "announced", "announcement", "release", "released",
            "launch", "launched", "update", "recent"
        ]
        return markers.contains { lower.contains($0) }
    }

    private static func normalizedSearchQuery(_ query: String, isNewsQuery: Bool) -> String {
        var value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandPatterns = [
            #"(?i)\bsearch\s+the\s+(web|internet)\s*(for|:)?\s*"#,
            #"(?i)\bsearch\s+(online\s+)?(for|:)\s*"#,
            #"(?i)\blook\s+up\s+"#,
            #"(?i)\bfind\s+(online\s+)?"#
        ]
        for pattern in commandPatterns {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        if isNewsQuery {
            let timeModifierPatterns = [
                #"(?i)\btoday'?s\b"#,
                #"(?i)\btoday\b"#,
                #"(?i)\bcurrent\b"#,
                #"今天|今日"#
            ]
            for pattern in timeModifierPatterns {
                value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
            }
        }

        value = normalizeWhitespace(value)
        guard !value.isEmpty else { return query }

        if isNewsQuery, firstCapture(pattern: #"20\d{2}"#, in: value) == nil {
            let year = Calendar.current.component(.year, from: Date())
            value += " \(year)"
        }
        return value
    }

    private static func isLikelySourceEntry(_ result: SearchResult) -> Bool {
        if let publishedAt = result.publishedAt, !publishedAt.isEmpty {
            return false
        }

        let text = "\(result.title) \(result.snippet)".lowercased()
        let sourcePhrases = [
            "首页", "主页", "频道", "栏目", "网站", "平台", "门户", "新闻头条", "行业动态",
            "总览", "提供", "覆盖", "致力于", "内容涵盖", "每日更新", "一站式", "快速播报", "查看", "模型卡", "评测", "参数",
            "home", "homepage", "category", "channel", "portal", "website", "latest stories",
            "your online source", "covers", "covering", "provides", "daily updates", "model card", "specs", "columns"
        ]
        if sourcePhrases.contains(where: { text.contains($0) }) {
            return true
        }

        guard let url = URL(string: result.url) else {
            return false
        }
        let pathComponents = url.path
            .split(separator: "/")
            .filter { !$0.isEmpty }
        let shallowPath = pathComponents.count <= 2
        let genericTitlePhrases = [
            "新闻", "资讯", "动态", "科技", "ai", "news", "latest", "updates", "stories"
        ]
        return shallowPath && genericTitlePhrases.contains { text.contains($0) }
    }

    private static func isLikelyUnconfirmedEntry(_ result: SearchResult) -> Bool {
        let text = "\(result.title) \(result.snippet)".lowercased()
        let markers = [
            "未官宣", "被曝", "曝光", "传闻", "据称", "有望", "可能", "爆料", "泄露", "流出",
            "rumor", "rumour", "leak", "leaked", "reportedly", "unannounced", "expected to", "could",
            "may already", "may be", "may have", "may soon", "may launch", "may release"
        ]
        return markers.contains { text.contains($0) }
    }

    private static func exactQueryTerms(_ query: String) -> [String] {
        let matches = regexMatches(
            pattern: #"[A-Za-z]+[- ]?\d+(?:\.\d+)+"#,
            in: query,
            options: [.caseInsensitive]
        )
        var seen = Set<String>()
        var terms: [String] = []
        for match in matches {
            let term = substring(query, nsRange: match.range)
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
            guard !term.isEmpty, !seen.contains(term) else { continue }
            seen.insert(term)
            terms.append(term)
        }
        return terms
    }

    private static func resultMatchesExactTerms(_ result: SearchResult, exactTerms: [String]) -> Bool {
        let text = "\(result.title) \(result.snippet) \(result.url)"
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return exactTerms.allSatisfy { text.contains($0) }
    }

    private static func newsSearchQuery(_ query: String) -> String {
        if firstCapture(pattern: #"20\d{2}"#, in: query) != nil {
            return query
        }
        let year = Calendar.current.component(.year, from: Date())
        return "\(query) \(year)"
    }

    private static func regexMatches(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1 else {
            return nil
        }
        return capture(1, from: match, in: text)
    }

    private static func capture(_ index: Int, from match: NSTextCheckingResult, in text: String) -> String? {
        guard match.numberOfRanges > index,
              let range = Range(match.range(at: index), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func substring(_ text: String, nsRange: NSRange) -> String {
        guard nsRange.location >= 0,
              nsRange.length >= 0,
              NSMaxRange(nsRange) <= text.utf16.count,
              let range = Range(nsRange, in: text) else {
            return ""
        }
        return String(text[range])
    }
}

private final class BingRSSParser: NSObject, XMLParserDelegate {
    private struct Item {
        var title = ""
        var link = ""
        var description = ""
        var pubDate = ""
    }

    private let source: String
    private var results: [WebTools.SearchResult] = []
    private var currentItem: Item?
    private var currentElement = ""
    private var buffer = ""

    init(source: String) {
        self.source = source
        super.init()
    }

    func parse(data: Data) -> [WebTools.SearchResult] {
        results = []
        currentItem = nil
        currentElement = ""
        buffer = ""

        let parser = XMLParser(data: data)
        parser.delegate = self
        _ = parser.parse()
        return results
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        buffer = ""
        if currentElement == "item" {
            currentItem = Item()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = elementName.lowercased()
        let value = WebTools.stripHTML(buffer)

        if var item = currentItem {
            switch element {
            case "title":
                item.title = value
            case "link":
                item.link = value
            case "description":
                item.description = value
            case "pubdate":
                item.pubDate = value
            case "item":
                if !item.title.isEmpty, !item.link.isEmpty {
                    results.append(WebTools.SearchResult(
                        title: item.title,
                        url: item.link,
                        snippet: item.description,
                        source: source,
                        publishedAt: item.pubDate.isEmpty ? nil : item.pubDate
                    ))
                }
                currentItem = nil
                buffer = ""
                return
            default:
                break
            }
            currentItem = item
        }

        if currentElement == element {
            buffer = ""
            currentElement = ""
        }
    }
}
