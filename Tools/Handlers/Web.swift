import Foundation

enum WebTools {

    private enum EvidenceConfidence: String {
        case high
        case medium
        case low
    }

    fileprivate struct SearchResult: Sendable {
        let title: String
        let url: String
        let snippet: String
        let source: String
        let publishedAt: String?

        func dictionary(rank: Int) -> [String: Any] {
            let homepageLike = WebTools.isHomepageLikeURL(url)
            let hasConcreteData = WebTools.hasConcreteDataSignal(snippet)
                || ((publishedAt?.isEmpty == false) && snippet.count >= 40)
            let needsFetch = homepageLike || !hasConcreteData
            let confidence: EvidenceConfidence = {
                if homepageLike { return .low }
                if hasConcreteData && snippet.count >= 120 { return .high }
                if hasConcreteData { return .medium }
                if snippet.isEmpty { return .low }
                return .medium
            }()
            var value: [String: Any] = [
                "rank": rank,
                "title": title,
                "url": url,
                "host": WebTools.hostName(from: url),
                "snippet": snippet,
                "source": source,
                "confidence": confidence.rawValue,
                "needs_fetch": needsFetch,
                "is_homepage_like": homepageLike,
                "has_concrete_data": hasConcreteData,
                "directly_usable": !homepageLike && !snippet.isEmpty && !needsFetch && confidence != .low
            ]
            if let publishedAt, !publishedAt.isEmpty {
                value["published_at"] = publishedAt
            }
            return value
        }
    }

    private struct SearchPlan: Sendable {
        let originalQuery: String
        let normalizedQuery: String
        let queries: [String]
        let freshness: String
        let locale: String
        let generatedAt: String
        let planner: String
        let strategy: String

        var dictionary: [String: Any] {
            [
                "original_query": originalQuery,
                "normalized_query": normalizedQuery,
                "queries": queries,
                "freshness": freshness,
                "locale": locale,
                "generated_at": generatedAt,
                "planner": planner,
                "strategy": strategy
            ]
        }
    }

    private struct SearchDocument: Sendable {
        let title: String
        let url: String
        let host: String
        let content: String
        let sourceRank: Int
        let publishedAt: String?
        let fetchedAt: String
        let truncated: Bool
    }

    private struct EvidenceChunk: Sendable {
        let id: String
        let title: String
        let url: String
        let host: String
        let text: String
        let sourceType: String
        let sourceRank: Int
        let score: Double
        let matchedConcepts: Int
        let hasConcreteData: Bool
        let publishedAt: String?
        let fetchedAt: String?

        var dictionary: [String: Any] {
            var value: [String: Any] = [
                "id": id,
                "title": title,
                "url": url,
                "host": host,
                "text": text,
                "source_type": sourceType,
                "source_rank": sourceRank,
                "score": score,
                "matched_concepts": matchedConcepts,
                "has_concrete_data": hasConcreteData
            ]
            if let publishedAt, !publishedAt.isEmpty {
                value["published_at"] = publishedAt
            }
            if let fetchedAt, !fetchedAt.isEmpty {
                value["fetched_at"] = fetchedAt
            }
            return value
        }
    }

    private struct WebRAGPack: Sendable {
        let sufficiency: String
        let chunks: [EvidenceChunk]
        let fetchedDocumentCount: Int
        let failedFetchCount: Int

        var hasSufficientEvidence: Bool {
            sufficiency == "sufficient"
        }

        var dictionary: [String: Any] {
            [
                "version": "web_rag_v1",
                "phone_ground": [
                    "version": "phoneground_v0",
                    "evidence_type": PhoneGroundEvidenceType.web.rawValue,
                    "answer_contract": PhoneGroundAnswerContract.groundedSources.rawValue
                ],
                "sufficiency": sufficiency,
                "chunk_count": chunks.count,
                "fetched_document_count": fetchedDocumentCount,
                "failed_fetch_count": failedFetchCount,
                "chunks": chunks.map(\.dictionary)
            ]
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
                return tr("URL 无效", "Invalid URL", "URL が無効です")
            case .unsupportedURLScheme:
                return tr("只支持 http/https URL", "Only http/https URLs are supported", "http/https の URL のみ対応しています")
            case .httpStatus(let status):
                return tr("HTTP \(status)", "HTTP \(status)")
            case .blocked(let provider):
                return tr("\(provider) 暂时拒绝了自动搜索请求", "\(provider) temporarily blocked automated search", "\(provider) が自動検索リクエストを一時的に拒否しました")
            case .emptyResponse:
                return tr("网页没有返回可读取内容", "The page returned no readable content", "ページから読み取れる内容が返されませんでした")
            }
        }
    }

    private actor SearchProviderCircuitBreaker {
        private struct State {
            var timeoutCount: Int = 0
            var disabledUntil: Date?
        }

        private var states: [String: State] = [:]
        private let timeoutThreshold = 2
        private let cooldown: TimeInterval = 5 * 60

        func skipReason(for provider: String, now: Date = Date()) -> String? {
            guard var state = states[provider],
                  let disabledUntil = state.disabledUntil else {
                return nil
            }
            if disabledUntil > now {
                let seconds = max(1, Int(disabledUntil.timeIntervalSince(now).rounded(.up)))
                return "skipped: provider cooling down after repeated timeouts (\(seconds)s remaining)"
            }
            state.disabledUntil = nil
            state.timeoutCount = 0
            states[provider] = state
            return nil
        }

        func recordSuccess(provider: String) {
            states[provider] = nil
        }

        func recordFailure(provider: String, error: Error, now: Date = Date()) -> String? {
            guard Self.isTimeout(error) else { return nil }
            var state = states[provider] ?? State()
            state.timeoutCount += 1
            if state.timeoutCount >= timeoutThreshold {
                let disabledUntil = now.addingTimeInterval(cooldown)
                state.disabledUntil = disabledUntil
                states[provider] = state
                return "provider-circuit: disabled \(provider) for \(Int(cooldown))s after \(state.timeoutCount) timeout(s)"
            }
            states[provider] = state
            return nil
        }

        private static func isTimeout(_ error: Error) -> Bool {
            if let urlError = error as? URLError {
                return urlError.code == .timedOut
            }
            let nsError = error as NSError
            return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
        }
    }

    private static let providerCircuitBreaker = SearchProviderCircuitBreaker()

    static func register(into registry: ToolRegistry) {
        registry.register(RegisteredTool(
            name: "web-search",
            description: tr(
                "免费联网搜索实时网页信息；无需 API key，默认使用公开搜索结果页，失败时会自动尝试备用来源",
                "Search the live web for current information for free; no API key required, using public search result pages with fallback sources",
                "リアルタイムのウェブ情報を無料で検索します。API キー不要で、公開の検索結果ページを使用し、失敗時には自動で代替ソースを試します"
            ),
            parameters: tr(
                "query: 搜索关键词, question: 用户原问题（可选，用于保留时间/地点/约束）, planned_queries: 查询规划器生成的 2-4 条搜索词（可选）, max_results: 返回结果数（可选，默认 5，最多 8）。保留用户原始时间、地点和主体；不要把“今天/最新”机械改写成年份。",
                "query: search query, question: original user question (optional, preserves time/location/constraints), planned_queries: 2-4 search queries generated by the query planner (optional), max_results: number of results (optional, default 5, max 8). Preserve the user's original time, location, and subject; do not mechanically rewrite “today/latest” into a year.",
                "query: 検索キーワード, question: ユーザーの元の質問（任意。時間/場所/制約を保持するため）, planned_queries: クエリプランナーが生成した 2〜4 件の検索語（任意）, max_results: 返す結果数（任意。デフォルト 5、最大 8）。ユーザー本来の時間・場所・主体を保持し、「今日/最新」を機械的に年に書き換えないこと。"
            ),
            phoneGroundContract: PhoneGroundToolContract(
                evidenceTypes: [.web],
                answerContract: .groundedSources,
                freshness: .realtime,
                supportsRecovery: true
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
                "Fetch a public webpage and convert the readable body to plain text for the model",
                "公開ウェブページの本文を読み取り、モデルが使いやすいプレーンテキストに変換します"
            ),
            parameters: tr(
                "url: 要读取的网页 URL, max_characters: 最大返回字符数（可选，默认 6000，最多 12000）",
                "url: webpage URL to read, max_characters: maximum returned characters (optional, default 6000, max 12000)",
                "url: 読み取るウェブページの URL, max_characters: 返す最大文字数（任意。デフォルト 6000、最大 12000）"
            ),
            phoneGroundContract: PhoneGroundToolContract(
                evidenceTypes: [.web],
                answerContract: .groundedSources,
                freshness: .realtime,
                supportsRecovery: true
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
                summary: tr("要搜索什么?", "What should I search for?", "何を検索しますか?"),
                detail: tr("缺少 query 参数", "Missing query parameter", "query パラメータがありません"),
                errorCode: "WEB_SEARCH_QUERY_MISSING"
            )
        }

        let maxResults = clampedInt(args["max_results"], defaultValue: 5, minValue: 1, maxValue: 8)
        let fetchedAt = iso8601String(from: Date())
        let originalQuestion = {
            let question = stringArgument(args["question"])
            return question.isEmpty ? query : question
        }()
        let providerQuery = normalizedSearchQuery(query)
        let plannedQueries = stringArrayArgument(args["planned_queries"])
        // Temporal intent drives the retrieval-side time filter and stale-result
        // rejection. For explicit "today/latest" questions, old dated fallback
        // results are worse than no result because they can be mistaken for
        // current news.
        let freshnessWindow = WebFreshness.window(for: originalQuestion)
        let plan = makeSearchPlan(
            originalQuery: originalQuestion,
            normalizedQuery: providerQuery,
            fetchedAt: fetchedAt,
            plannedQueries: plannedQueries
        )
        var providerErrors: [String] = []

        let providers: [(String, (String, Int, WebFreshness.Window) async throws -> [SearchResult])] = [
            ("bing-rss", searchBingRSS),
            ("bing-news-rss", searchBingNewsRSS),
            ("duckduckgo-html", searchDuckDuckGo)
        ]

        var allResults: [SearchResult] = []
        for plannedQuery in plan.queries {
            for (providerName, provider) in providers {
                if let skipReason = await providerCircuitBreaker.skipReason(for: providerName) {
                    providerErrors.append("\(providerName) [\(plannedQuery)]: \(skipReason)")
                    continue
                }
                if providerName == "duckduckgo-html",
                   hasEnoughFreshResults(allResults, maxResults: maxResults, window: freshnessWindow) {
                    providerErrors.append("\(providerName) [\(plannedQuery)]: skipped: enough results from RSS providers")
                    continue
                }
                do {
                    let results = uniqueResults(try await provider(plannedQuery, maxResults, freshnessWindow))
                    await providerCircuitBreaker.recordSuccess(provider: providerName)
                    if results.isEmpty {
                        providerErrors.append("\(providerName) [\(plannedQuery)]: empty")
                    } else {
                        allResults.append(contentsOf: results)
                    }
                } catch {
                    if let circuitMessage = await providerCircuitBreaker.recordFailure(provider: providerName, error: error) {
                        providerErrors.append(circuitMessage)
                    }
                    providerErrors.append("\(providerName) [\(plannedQuery)]: \(error.localizedDescription)")
                }
            }
        }

        let uniqueMergedResults = uniqueResults(allResults)
        let now = Date()
        let freshnessFilteredResults = freshnessFilteredSearchResults(
            uniqueMergedResults,
            window: freshnessWindow,
            now: now
        )
        let staleDroppedCount = uniqueMergedResults.count - freshnessFilteredResults.count
        if staleDroppedCount > 0 {
            providerErrors.append("freshness-filter: dropped \(staleDroppedCount) stale dated result(s)")
        }

        let mergedResults = freshnessFilteredResults
            .sorted { lhs, rhs in
                searchResultSort(lhs, rhs, query: originalQuestion)
            }
            .prefix(maxResults)
            .map { $0 }
        if !mergedResults.isEmpty {
            let evidencePack = await buildEvidencePack(
                plan: plan,
                fetchedAt: fetchedAt,
                results: mergedResults,
                window: freshnessWindow
            )
            return searchSuccess(
                originalQuery: query,
                userQuestion: originalQuestion,
                providerQuery: providerQuery,
                plan: plan,
                fetchedAt: fetchedAt,
                provider: "merged",
                results: mergedResults,
                evidencePack: evidencePack,
                window: freshnessWindow,
                providerErrors: providerErrors
            )
        }

        let staleOnly = !uniqueMergedResults.isEmpty && freshnessFilteredResults.isEmpty && freshnessWindow != .none
        let summary = staleOnly
            ? tr(
                "没有找到满足当前时间要求的实时搜索结果。",
                "No live search results matched the requested freshness window.",
                "指定された新しさに合うリアルタイム検索結果が見つかりませんでした。"
            )
            : providerErrors.allSatisfy { $0.contains(": empty") }
            ? tr(
                "没有找到可用的实时搜索结果。",
                "No live search results were available.",
                "利用できるリアルタイム検索結果が見つかりませんでした。"
            )
            : tr(
                "实时搜索失败。免费搜索来源可能暂时限流或网络超时。",
                "Live search failed. Free search sources may be rate-limited or timed out.",
                "リアルタイム検索に失敗しました。無料の検索ソースが一時的に制限されているか、ネットワークがタイムアウトした可能性があります。"
            )
        return webFailure(
            summary: summary,
            detail: providerErrors.joined(separator: "\n"),
            errorCode: "WEB_SEARCH_FAILED",
            extras: [
                "query": providerQuery,
                "original_query": originalQuestion,
                "query_plan": plan.dictionary,
                "fetched_at": fetchedAt,
                "provider": "none",
                "provider_errors": providerErrors,
                "stale_result_count": staleDroppedCount,
                "results": []
            ]
        )
    }

    private static func fetchCanonical(_ args: [String: Any]) async -> CanonicalToolResult {
        let rawURL = stringArgument(args["url"])
        guard !rawURL.isEmpty else {
            return webFailure(
                summary: tr("要读取哪个链接?", "Which URL should I read?", "どのリンクを読み取りますか?"),
                detail: tr("缺少 url 参数", "Missing url parameter", "url パラメータがありません"),
                errorCode: "WEB_FETCH_URL_MISSING"
            )
        }

        guard let parsedURL = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return webFailure(
                summary: tr("这个链接格式不对。", "That URL is not valid.", "このリンクの形式が正しくありません。"),
                detail: tr("URL 无效: \(rawURL)", "Invalid URL: \(rawURL)", "無効な URL: \(rawURL)"),
                errorCode: "WEB_FETCH_INVALID_URL"
            )
        }

        guard ["http", "https"].contains((parsedURL.scheme ?? "").lowercased()) else {
            return webFailure(
                summary: tr("只支持读取 http/https 网页。", "Only http/https webpages are supported.", "http/https のウェブページのみ読み取れます。"),
                detail: tr("不支持的 URL scheme: \(parsedURL.scheme ?? "")", "Unsupported URL scheme: \(parsedURL.scheme ?? "")", "サポートされていない URL スキーム: \(parsedURL.scheme ?? "")"),
                errorCode: "WEB_FETCH_UNSUPPORTED_SCHEME"
            )
        }

        let url = httpsUpgradedURLIfNeeded(parsedURL)

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
                    "phone_ground": webPhoneGroundMetadata(status: "succeeded"),
                    "url": fetched.finalURL,
                    "title": fetched.title,
                    "content": fetched.content,
                    "has_concrete_data": hasConcreteDataSignal(fetched.content),
                    "looks_like_boilerplate": looksLikeBoilerplatePage(fetched.content),
                    "truncated": fetched.truncated,
                    "published_at": fetched.publishedAt ?? "",
                    "fetched_at": iso8601String(from: Date())
                ]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)
        } catch {
            return webFailure(
                summary: tr(
                    "网页读取失败：\(error.localizedDescription)",
                    "Webpage fetch failed: \(error.localizedDescription)",
                    "ウェブページの読み取りに失敗しました：\(error.localizedDescription)"
                ),
                detail: error.localizedDescription,
                errorCode: "WEB_FETCH_FAILED"
            )
        }
    }

    // MARK: - Search Providers

    private static func searchDuckDuckGo(query: String, maxResults: Int, window: WebFreshness.Window) async throws -> [SearchResult] {
        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else {
            throw WebToolError.invalidURL
        }
        var items = [URLQueryItem(name: "q", value: query)]
        // Region/locale lock. Without kl, html.duckduckgo.com geolocates by exit IP
        // and returns region-mismatched, foreign-language pages (observed: Indonesian
        // / Vietnamese results for a 中文 "今天的 AI 新闻" query), and differently per
        // request — the main cause of "搜到的根本不是想要的内容" + run-to-run variance.
        // Derived from the conversation language, not IP.
        items.append(URLQueryItem(name: "kl", value: LanguageService.shared.current.duckDuckGoRegion))
        // Native recency filter: df=d/w/m restricts to the past day/week/month.
        // This asks the engine for fresh pages instead of trying (and failing) to
        // detect freshness after the fact with literal date-string matching.
        if let df = window.duckDuckGoFilter {
            items.append(URLQueryItem(name: "df", value: df))
        }
        components.queryItems = items
        guard let url = components.url else { throw WebToolError.invalidURL }

        let html = try await fetchText(url: url, accept: "text/html", timeout: 4)
        if html.contains("anomaly-modal") || html.contains("Unfortunately, bots use DuckDuckGo too") {
            throw WebToolError.blocked("DuckDuckGo")
        }

        var results = parseDuckDuckGoResultAnchors(html, maxResults: maxResults)
        if results.isEmpty {
            results = parseDuckDuckGoLiteAnchors(html, maxResults: maxResults)
        }
        return results
    }

    private static func searchBingRSS(query: String, maxResults: Int, window: WebFreshness.Window) async throws -> [SearchResult] {
        guard var components = URLComponents(string: "https://www.bing.com/search") else {
            throw WebToolError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "format", value: "rss"),
            URLQueryItem(name: "setlang", value: LanguageService.shared.current.isJapanese ? "ja-JP" : (LanguageService.shared.current.isChinese ? "zh-CN" : "en-US")),
            URLQueryItem(name: "cc", value: LanguageService.shared.current.isJapanese ? "JP" : (LanguageService.shared.current.isChinese ? "CN" : "US")),
            URLQueryItem(name: "q", value: query)
        ]
        guard let url = components.url else { throw WebToolError.invalidURL }

        let data = try await fetchData(url: url, accept: "application/rss+xml, application/xml, text/xml")
        let parser = BingRSSParser(source: "bing-rss")
        let results = parser.parse(data: data)
        return Array(results.prefix(maxResults))
    }

    private static func searchBingNewsRSS(query: String, maxResults: Int, window: WebFreshness.Window) async throws -> [SearchResult] {
        guard var components = URLComponents(string: "https://www.bing.com/news/search") else {
            throw WebToolError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "format", value: "rss"),
            URLQueryItem(name: "setlang", value: LanguageService.shared.current.isJapanese ? "ja-JP" : (LanguageService.shared.current.isChinese ? "zh-CN" : "en-US")),
            URLQueryItem(name: "cc", value: LanguageService.shared.current.isJapanese ? "JP" : (LanguageService.shared.current.isChinese ? "CN" : "US")),
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
    ) async throws -> (title: String, finalURL: String, content: String, truncated: Bool, publishedAt: String?) {
        let data = try await fetchData(url: url, accept: "text/html, text/plain, application/xhtml+xml")
        let limitedData = data.count > 2_000_000 ? Data(data.prefix(2_000_000)) : data
        let html = String(decoding: limitedData, as: UTF8.self)
        let title = extractTitle(from: html)
        let publishedAt = extractPublishedAt(from: html)
        let body = readableText(from: html)
        guard !body.isEmpty else { throw WebToolError.emptyResponse }

        let clipped = clippedText(body, maxCharacters: maxCharacters)
        return (
            title: title.isEmpty ? url.host ?? url.absoluteString : title,
            finalURL: url.absoluteString,
            content: clipped.text,
            truncated: clipped.truncated || data.count > limitedData.count,
            publishedAt: publishedAt
        )
    }

    /// Best-effort publish timestamp from page metadata: Open Graph article time,
    /// common `<meta name=date>` variants, schema.org `datePublished` (meta or
    /// JSON-LD), and `<time datetime>`. Returns the raw string for WebFreshness to
    /// parse; nil when the page exposes no machine-readable date.
    private static func extractPublishedAt(from html: String) -> String? {
        let patterns = [
            #"<meta[^>]+(?:property|name|itemprop)=["'](?:article:published_time|article:modified_time|datePublished|date|pubdate|publishdate|publish-date|DC\.date\.issued|sailthru\.date)["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name|itemprop)=["'](?:article:published_time|datePublished|date|pubdate)["']"#,
            #"["']datePublished["']\s*:\s*["']([^"']+)["']"#,
            #"<time[^>]+datetime=["']([^"']+)["']"#
        ]
        for pattern in patterns {
            if let raw = firstCapture(pattern: pattern, in: html) {
                let value = htmlDecode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func fetchData(url: URL, accept: String, timeout: TimeInterval = 10) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
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

    private static func fetchText(url: URL, accept: String, timeout: TimeInterval = 10) async throws -> String {
        let data = try await fetchData(url: url, accept: accept, timeout: timeout)
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

    // MARK: - Ephemeral Web RAG

    /// Remove injected absolute-date tokens ("2026-06-06", "2026/6/6", "2026年6月6日")
    /// from a planned query. These are recency the planner shouldn't put in the query
    /// text — search engines exact-match them to calendar/year pages. Recency is carried
    /// by the provider time filter (df) + recency ranking instead. Bare years ("2008")
    /// and the user's own time range are intentionally left intact (not full Y-M-D dates).
    private static func stripInjectedDateTokens(_ query: String) -> String {
        var result = query
        let datePatterns = [
            #"\d{4}\s*[-/.]\s*\d{1,2}\s*[-/.]\s*\d{1,2}"#,
            #"\d{4}\s*年\s*\d{1,2}\s*月\s*\d{1,2}\s*日?"#
        ]
        for pattern in datePatterns {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return normalizeWhitespace(result)
    }

    private static func makeSearchPlan(
        originalQuery: String,
        normalizedQuery: String,
        fetchedAt: String,
        plannedQueries: [String] = []
    ) -> SearchPlan {
        let cleanedPlanned = uniqueTerms(plannedQueries.map(normalizeWhitespace))
            .filter { !$0.isEmpty && $0.count <= 120 }
        var candidates: [String]
        let planner: String
        let strategy: String
        if !cleanedPlanned.isEmpty {
            // Strip injected absolute-date tokens the model sometimes adds for recency
            // (e.g. "AI 新闻 2026-06-06"). Search engines treat them as required keywords
            // and match calendar/year/schedule pages; recency is handled by the provider
            // time filter (df) + recency ranking. Same philosophy as the tool_default
            // branch below — the model path just didn't enforce it. Bare years and the
            // user's own time range survive (only full Y-M-D dates are removed).
            let stripped = uniqueTerms(cleanedPlanned.map(stripInjectedDateTokens))
                .filter { !$0.isEmpty }
            candidates = stripped.isEmpty ? cleanedPlanned : stripped
            planner = "agent_model"
            strategy = "web_rag_v2_model_query_plan"
        } else {
            candidates = [normalizedQuery, originalQuery]

            let conceptQuery = significantQueryConcepts(originalQuery)
                .compactMap(\.first)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !conceptQuery.isEmpty {
                candidates.append(conceptQuery)
            }

            // Deliberately do NOT append a literal date token (e.g. "2026-06-06")
            // to the query. Search engines treat it as a required keyword and it
            // hurts recall; recency is handled by the provider time filter (df)
            // and recency-weighted ranking instead.
            planner = "tool_default"
            strategy = "web_rag_v1_generic_query_plan"
        }

        let queries = uniqueTerms(candidates.map(normalizeWhitespace))
            .filter { !$0.isEmpty }
            .prefix(4)
        return SearchPlan(
            originalQuery: originalQuery,
            normalizedQuery: normalizedQuery,
            queries: Array(queries),
            freshness: queryNeedsFreshness(originalQuery) ? "current" : "unspecified",
            locale: LanguageService.shared.current.isChinese ? "zh-CN" : "en-US",
            generatedAt: fetchedAt,
            planner: planner,
            strategy: strategy
        )
    }

    private static func buildEvidencePack(
        plan: SearchPlan,
        fetchedAt: String,
        results: [SearchResult],
        window: WebFreshness.Window
    ) async -> WebRAGPack {
        // Relevance matches against the cleaned search query (no command words),
        // not the raw question. Freshness uses the raw question (handled upstream
        // via `window`), so temporal words like 今天/昨天 are preserved there.
        let relevanceQuery = plan.normalizedQuery
        // No freshness pre-filter: stale-for-query items rank lower (recency
        // weight below), they are never dropped. Dropping them is what made the
        // pack empty and forced a refusal even when fresh news existed.
        let snippetChunks = searchSnippetEvidenceChunks(
            results: results,
            fetchedAt: fetchedAt
        )
        let fetchOutcome = await fetchDocuments(
            results: Array(results.prefix(4)),
            fetchedAt: fetchedAt
        )
        let documentChunks = fetchOutcome.documents.flatMap { document in
            documentEvidenceChunks(
                document: document,
                originalQuery: relevanceQuery
            )
        }
        let rankedChunks = rankEvidenceChunks(
            snippetChunks + documentChunks,
            originalQuery: relevanceQuery,
            window: window
        )
        // Diversify across sources so one dense aggregator page can't monopolize
        // the pack. A small model turns a diverse set of distinct items into
        // several bullets; 8 near-duplicate chunks from one host collapse into a
        // single vague point.
        let topChunks = diversifyEvidenceChunks(rankedChunks, limit: 8, perHostCap: 2)
        return WebRAGPack(
            sufficiency: evidenceSufficiency(topChunks, originalQuery: relevanceQuery),
            chunks: topChunks,
            fetchedDocumentCount: fetchOutcome.documents.count,
            failedFetchCount: fetchOutcome.failedCount
        )
    }

    /// Pick the top `limit` chunks but allow at most `perHostCap` from any one
    /// host on the first pass, so a single aggregator/homepage page can't fill
    /// the whole pack. Remaining slots are filled from leftovers (cap relaxed).
    private static func diversifyEvidenceChunks(
        _ ranked: [EvidenceChunk],
        limit: Int,
        perHostCap: Int
    ) -> [EvidenceChunk] {
        var picked: [EvidenceChunk] = []
        var hostCount: [String: Int] = [:]
        for chunk in ranked {
            let key = chunk.host.isEmpty ? chunk.url : chunk.host
            if (hostCount[key] ?? 0) >= perHostCap { continue }
            picked.append(chunk)
            hostCount[key, default: 0] += 1
            if picked.count >= limit { return picked }
        }
        if picked.count < limit {
            let pickedIDs = Set(picked.map(\.id))
            for chunk in ranked where !pickedIDs.contains(chunk.id) {
                picked.append(chunk)
                if picked.count >= limit { break }
            }
        }
        return picked
    }

    private static func searchSnippetEvidenceChunks(
        results: [SearchResult],
        fetchedAt: String
    ) -> [EvidenceChunk] {
        results.enumerated().compactMap { index, result in
            let text = result.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 40 else { return nil }
            return EvidenceChunk(
                id: "s\(index + 1)",
                title: result.title,
                url: result.url,
                host: hostName(from: result.url),
                text: clippedText(text, maxCharacters: 650).text,
                sourceType: "search_snippet",
                sourceRank: index + 1,
                score: 0,
                matchedConcepts: 0,
                hasConcreteData: hasConcreteDataSignal(text),
                publishedAt: result.publishedAt,
                fetchedAt: fetchedAt
            )
        }
    }

    private static func fetchDocuments(
        results: [SearchResult],
        fetchedAt: String
    ) async -> (documents: [SearchDocument], failedCount: Int) {
        await withTaskGroup(of: SearchDocument?.self) { group in
            for (index, result) in results.enumerated() {
                guard let url = URL(string: result.url) else { continue }
                group.addTask {
                    do {
                        let fetched = try await fetchReadablePage(url: httpsUpgradedURLIfNeeded(url), maxCharacters: 9_000)
                        let content = fetched.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard content.count >= 180,
                              !looksLikeBoilerplatePage(content) else {
                            return nil
                        }
                        return SearchDocument(
                            title: fetched.title.isEmpty ? result.title : fetched.title,
                            url: fetched.finalURL,
                            host: hostName(from: fetched.finalURL),
                            content: content,
                            sourceRank: index + 1,
                            publishedAt: fetched.publishedAt ?? result.publishedAt,
                            fetchedAt: fetchedAt,
                            truncated: fetched.truncated
                        )
                    } catch {
                        return nil
                    }
                }
            }

            var documents: [SearchDocument] = []
            var completed = 0
            for await document in group {
                completed += 1
                if let document {
                    documents.append(document)
                }
            }
            return (
                documents.sorted { $0.sourceRank < $1.sourceRank },
                max(0, completed - documents.count)
            )
        }
    }

    private static func documentEvidenceChunks(
        document: SearchDocument,
        originalQuery: String
    ) -> [EvidenceChunk] {
        splitIntoEvidenceWindows(document.content, maxCharacters: 600).enumerated().map { index, text in
            EvidenceChunk(
                id: "d\(document.sourceRank)-\(index + 1)",
                title: document.title,
                url: document.url,
                host: document.host,
                text: text,
                sourceType: "web_page",
                sourceRank: document.sourceRank,
                score: 0,
                matchedConcepts: 0,
                hasConcreteData: hasConcreteDataSignal(text),
                publishedAt: document.publishedAt,
                fetchedAt: document.fetchedAt
            )
        }
    }

    private static func splitIntoEvidenceWindows(_ content: String, maxCharacters: Int) -> [String] {
        let paragraphs = content
            .components(separatedBy: .newlines)
            .map { normalizeWhitespace($0) }
            .filter { $0.count >= 20 }
        var chunks: [String] = []
        var current = ""

        for paragraph in paragraphs {
            if paragraph.count > maxCharacters {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                var remaining = paragraph
                while remaining.count > maxCharacters {
                    let end = remaining.index(remaining.startIndex, offsetBy: maxCharacters)
                    chunks.append(String(remaining[..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
                    remaining = String(remaining[end...])
                }
                if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    current = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continue
            }

            let candidate = current.isEmpty ? paragraph : "\(current)\n\(paragraph)"
            if candidate.count > maxCharacters {
                chunks.append(current)
                current = paragraph
            } else {
                current = candidate
            }
        }

        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static func rankEvidenceChunks(
        _ chunks: [EvidenceChunk],
        originalQuery: String,
        window: WebFreshness.Window
    ) -> [EvidenceChunk] {
        let concepts = significantQueryConcepts(originalQuery)
        let scored = chunks.compactMap { chunk -> EvidenceChunk? in
            let coverage = relevanceCoverage("\(chunk.title)\n\(chunk.text)", concepts: concepts)
            // Graded relevance: drop only the truly off-topic (zero coverage).
            // Ordering here only needs to surface a sensible *candidate set*
            // (relevance + recency + source order) — the real relevance judgment
            // and fact extraction are done by the model curation step downstream,
            // not by hand-tuned weights here.
            guard concepts.isEmpty || coverage > 0 else { return nil }
            var score = coverage * 100
            if window != .none {
                score += WebFreshness.recencyBoost(
                    publishedAt: chunk.publishedAt ?? "\(chunk.title)\n\(chunk.text)",
                    window: window,
                    maxBoost: 60
                )
            }
            score += Double(max(0, 12 - chunk.sourceRank))
            return EvidenceChunk(
                id: chunk.id,
                title: chunk.title,
                url: chunk.url,
                host: chunk.host,
                text: chunk.text,
                sourceType: chunk.sourceType,
                sourceRank: chunk.sourceRank,
                score: score,
                matchedConcepts: Int((coverage * Double(concepts.count)).rounded()),
                hasConcreteData: chunk.hasConcreteData,
                publishedAt: chunk.publishedAt,
                fetchedAt: chunk.fetchedAt
            )
        }
        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.sourceRank < rhs.sourceRank
        }
    }

    /// Continuous query coverage in [0,1]: the fraction of query concept-groups
    /// present in `text`. Graded, not a yes/no gate — a partial match ranks lower
    /// instead of being hard-mislabeled. General: no domain/keyword lists.
    private static func relevanceCoverage(_ text: String, concepts: [[String]]) -> Double {
        guard !concepts.isEmpty else { return 1 }
        let haystack = text.lowercased()
        let matched = concepts.reduce(into: 0) { count, alternatives in
            if alternatives.contains(where: { haystack.contains($0.lowercased()) }) {
                count += 1
            }
        }
        return Double(matched) / Double(concepts.count)
    }

    private static func evidenceSufficiency(
        _ chunks: [EvidenceChunk],
        originalQuery: String
    ) -> String {
        guard let best = chunks.first else { return "empty" }
        let concepts = significantQueryConcepts(originalQuery)
        let requiredMatches = concepts.count >= 2 ? 2 : 1
        if best.matchedConcepts >= requiredMatches,
           (best.hasConcreteData || chunks.count >= 2 || best.score >= 150) {
            return "sufficient"
        }
        return "thin"
    }

    private static func evidencePackSummary(_ pack: WebRAGPack) -> String {
        guard !pack.chunks.isEmpty else {
            return tr(
                "evidence_pack: 没有抽取到可用证据片段。",
                "evidence_pack: no usable evidence snippets were extracted.",
                "evidence_pack: 利用できる証拠スニペットを抽出できませんでした。"
            )
        }
        let lines = pack.chunks.prefix(8).map { chunk in
            let text = clippedText(chunk.text, maxCharacters: 240).text
            let meta = [
                "id=\(chunk.id)",
                "score=\(Int(chunk.score))",
                "source=\(chunk.sourceType)",
                "host=\(chunk.host)"
            ].joined(separator: ", ")
            return "[\(meta)] \(chunk.title)\nURL: \(chunk.url)\nEvidence: \(text)"
        }.joined(separator: "\n\n")
        return tr(
            "evidence_pack sufficiency=\(pack.sufficiency), chunks=\(pack.chunks.count), fetched_documents=\(pack.fetchedDocumentCount):\n\(lines)",
            "evidence_pack sufficiency=\(pack.sufficiency), chunks=\(pack.chunks.count), fetched_documents=\(pack.fetchedDocumentCount):\n\(lines)"
        )
    }

    private static func queryNeedsFreshness(_ query: String) -> Bool {
        let lower = query.lowercased()
        let markers = [
            "今天", "今日", "现在", "当前", "实时", "最近", "最新", "刚刚", "本周", "本月",
            "today", "now", "current", "latest", "recent", "this week", "this month"
        ]
        return markers.contains { lower.contains($0) }
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
        originalQuery: String,
        userQuestion: String,
        providerQuery: String,
        plan: SearchPlan,
        fetchedAt: String,
        provider: String,
        results: [SearchResult],
        evidencePack: WebRAGPack,
        window: WebFreshness.Window,
        providerErrors: [String]
    ) -> CanonicalToolResult {
        let now = Date()
        let parsedDates: [Date?] = results.map {
            WebFreshness.parsePublishedDate($0.publishedAt ?? "\($0.title)\n\($0.snippet)", now: now)
        }
        let evidenceResults = results.enumerated().map { index, item -> [String: Any] in
            var evidence = item.dictionary(rank: index + 1)
            // Relevance matches against the cleaned search query (the model already
            // stripped "联网搜索" etc.), not the raw question — otherwise the command
            // word becomes a required concept and mislabels on-topic results.
            evidence["query_relevant"] = searchResultMatchesQuery(item, query: providerQuery)
            if window != .none {
                evidence["freshness_ok"] = searchResultFreshEnough(item, window: window, now: now)
            }
            if let date = parsedDates[index] {
                evidence["published_at"] = iso8601String(from: date)
                evidence["age_days"] = Int((now.timeIntervalSince(date) / 86_400).rounded())
                if window != .none {
                    evidence["recency_score"] = WebFreshness.recencyScore(
                        ageSeconds: WebFreshness.ageInSeconds(of: date, now: now),
                        halfLifeHours: window.halfLifeHours
                    )
                }
            }
            return evidence
        }
        let directlyUsableResults = evidenceResults.filter { isDirectlyUsableSearchEvidence($0) }
        let needsFetchResults = evidenceResults.filter { ($0["needs_fetch"] as? Bool) == true }
        let directEvidenceSufficient = hasSufficientDirectEvidence(
            directCount: directlyUsableResults.count,
            needsFetchCount: needsFetchResults.count,
            totalCount: evidenceResults.count
        )
        // Freshness never turns a non-empty result set into "insufficient".
        // We answer with the freshest relevant evidence; the model states dates.
        let answerability = evidencePack.hasSufficientEvidence || directEvidenceSufficient ? "direct" : "needs_fetch"
        let freshestDate = parsedDates.compactMap { $0 }.max()
        let freshestAgeDays = freshestDate.map { Int((now.timeIntervalSince($0) / 86_400).rounded()) }
        let resultLines = results.enumerated().map { index, item in
            let title = clippedText(item.title, maxCharacters: 100).text
            let evidence = evidenceResults[index]
            var labels: [String] = []
            if let confidence = evidence["confidence"] as? String {
                labels.append("confidence:\(confidence)")
            }
            if evidence["directly_usable"] as? Bool == true {
                labels.append(tr("可直接用于回答", "directly usable", "回答にそのまま使用可能"))
            }
            if evidence["needs_fetch"] as? Bool == true {
                labels.append(tr("建议读取原文", "fetch recommended", "原文の読み取り推奨"))
            }
            if evidence["is_homepage_like"] as? Bool == true {
                labels.append(tr("可能是首页/入口页", "likely homepage/index", "トップページ/入口ページの可能性"))
            }
            if evidence["query_relevant"] as? Bool == false {
                labels.append(tr("主题相关性低", "low query relevance", "クエリとの関連性が低い"))
            }
            let labelPrefix = labels.isEmpty
                ? ""
                : labels.map { "[\($0)]" }.joined() + " "
            let snippet = clippedText(item.snippet, maxCharacters: 180).text
            let snippetPart = snippet.isEmpty ? "" : "\n   \(snippet)"
            let datePart = parsedDates[index].map {
                "\n   \(tr("发布时间", "Published", "公開日時")): \(freshnessAnnotation($0, now: now))"
            } ?? ""
            return "\(index + 1). \(labelPrefix)\(title)\n   \(tr("来源URL", "Source URL", "ソース URL")): \(item.url)\(datePart)\(snippetPart)"
        }.joined(separator: "\n")

        let ragGuidance = evidencePack.hasSufficientEvidence
            ? tr(
                "已抓取并抽取可用证据片段。最终回答必须只基于 evidence_pack.chunks；每个关键结论保留对应来源 URL/host。",
                "Readable pages were fetched and usable evidence snippets were extracted. The final answer must be grounded only in evidence_pack.chunks, preserving source URLs/hosts for key claims.",
                "読み取れるページを取得し、利用できる証拠スニペットを抽出しました。最終回答は evidence_pack.chunks のみに基づくこと。重要な結論ごとに対応するソースの URL/host を保持してください。"
            )
            : tr(
                "已尝试抓取并抽取证据，但证据仍偏薄；如果搜索结果中还有明显更相关的 URL，可读取原文，否则用现有最相关的结果作答。",
                "Page fetch and evidence extraction were attempted, but evidence is still thin; fetch another clearly relevant URL if available, otherwise answer from the most relevant results at hand.",
                "ページの取得と証拠抽出を試みましたが、証拠はまだ薄いです。検索結果に明らかにより関連性の高い URL があれば原文を読み取り、なければ手元の最も関連性の高い結果で回答してください。"
            )
        let freshnessGuidance = freshnessGuidanceText(window: window, freshestAgeDays: freshestAgeDays)
        let evidenceGuidance = !directEvidenceSufficient && !evidencePack.hasSufficientEvidence
            ? tr(
                "当前结果还不足以直接给出结论；请选择最相关的一个来源调用 web-fetch 读取正文。如果无法读取或正文仍不足，再用现有最相关的结果作答。",
                "The current results are not enough for a direct conclusion; choose the most relevant source and call web-fetch to read the page. If fetching fails or the page is still insufficient, answer from the most relevant results available.",
                "現在の結果だけでは結論を直接出すには不十分です。最も関連性の高いソースを 1 つ選び、web-fetch を呼んで本文を読み取ってください。読み取れない、または本文がなお不十分な場合は、手元の最も関連性の高い結果で回答してください。"
            )
            : tr(
                "其中 \(directlyUsableResults.count) 条结果有可直接使用的摘要/来源。回答时先给结论，保留来源 URL 和搜索时间；如果不同来源不一致，用不确定语气说明。",
                "\(directlyUsableResults.count) result(s) have directly usable snippets/sources. Start with the conclusion, preserve source URLs and search time, and use uncertain wording if sources disagree.",
                "そのうち \(directlyUsableResults.count) 件の結果にそのまま使える要約/ソースがあります。回答ではまず結論を述べ、ソース URL と検索時刻を保持してください。ソース間で内容が一致しない場合は不確実な言い回しで説明してください。"
            )
        let guidanceTail = [freshnessGuidance, evidenceGuidance]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let summary = tr(
            "实时搜索「\(originalQuery)」找到 \(results.count) 条结果（来源: \(provider)，搜索词: \(providerQuery)，搜索时间: \(fetchedAt)，answerability=\(answerability)）：\n\(ragGuidance)\n\(evidencePackSummary(evidencePack))\n\n\(guidanceTail)\n注意：以下是搜索结果条目，不等于已核实结论；confidence=low 或标为[建议读取原文]/[可能是首页/入口页]/[主题相关性低]的结果不能直接当作事实结论。\n\(resultLines)",
            "Live search for \"\(originalQuery)\" found \(results.count) result(s) (source: \(provider), query: \(providerQuery), fetched at: \(fetchedAt), answerability=\(answerability)):\n\(ragGuidance)\n\(evidencePackSummary(evidencePack))\n\n\(guidanceTail)\nNote: these are search result entries, not verified conclusions; confidence=low or items labeled [fetch recommended]/[likely homepage/index]/[low query relevance] must not be treated as final facts.\n\(resultLines)"
        )
        var extras: [String: Any] = [
            "query": providerQuery,
            "original_query": originalQuery,
            "user_question": userQuestion,
            "query_plan": plan.dictionary,
            "fetched_at": fetchedAt,
            "provider": provider,
            "phone_ground": webPhoneGroundMetadata(status: "succeeded"),
            "rag_version": "web_rag_v2",
            "evidence_pack": evidencePack.dictionary,
            "answerability": answerability,
            "direct_evidence_sufficient": evidencePack.hasSufficientEvidence || directEvidenceSufficient,
            "search_direct_evidence_sufficient": directEvidenceSufficient,
            "recency_window": String(describing: window),
            "direct_answer_result_count": directlyUsableResults.count,
            "needs_fetch_result_count": needsFetchResults.count,
            "results": evidenceResults
        ]
        if let freshestDate {
            extras["freshest_published_at"] = iso8601String(from: freshestDate)
        }
        if let freshestAgeDays {
            extras["freshest_age_days"] = freshestAgeDays
        }
        if !providerErrors.isEmpty {
            extras["provider_errors"] = providerErrors
        }
        let detail = successPayload(result: summary, extras: extras)
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
    }

    /// Human-readable date + relative age, e.g. "2026-06-06 (今天)" / "2026-06-05 (1天前)".
    /// Lets the model state when each item was published instead of guessing.
    private static func freshnessAnnotation(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let iso = formatter.string(from: date)
        let days = Int((now.timeIntervalSince(date) / 86_400).rounded())
        let rel: String
        if days <= 0 {
            rel = tr("今天", "today")
        } else if days == 1 {
            rel = tr("1天前", "1 day ago")
        } else {
            rel = tr("\(days)天前", "\(days) days ago")
        }
        return "\(iso) (\(rel))"
    }

    /// Retrieval-side guidance about recency. It tells the model to lead with the
    /// freshest evidence and — crucially — to be honest (not refuse) when nothing
    /// strictly inside the requested window was found. Empty for non-temporal queries.
    private static func freshnessGuidanceText(window: WebFreshness.Window, freshestAgeDays: Int?) -> String {
        guard window != .none else { return "" }
        if let days = freshestAgeDays, days <= toleranceDays(for: window) {
            return tr(
                "这是时效性问题。回答时先给最新的相关条目，并标注其发布时间，按时间从新到旧组织。",
                "This is a time-sensitive question. Lead with the freshest relevant items, state each item's publish date, and organize newest-first."
            )
        }
        return tr(
            "这是时效性问题，但没有检索到严格落在时间窗口内的结果。请如实说明“没有找到更新的，以下是检索到的最新内容（注明发布时间）”，然后照常给出最新的相关条目并标注日期——不要拒答，也不要谎称是当天内容。",
            "This is a time-sensitive question, but nothing strictly inside the requested window was found. Say plainly \"nothing more recent was found; here is the latest available (with its publish date)\", then still give the freshest relevant items with their dates — do not refuse, and do not claim stale items are same-day."
        )
    }

    /// Soft window tolerance (days) used only to decide answer *wording*
    /// (lead-with-freshest vs honest-hedge). It never gates whether we answer.
    private static func toleranceDays(for window: WebFreshness.Window) -> Int {
        switch window {
        case .day: return 2
        case .week: return 9
        case .month: return 40
        case .none: return Int.max
        }
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

    private static func webFailure(
        summary: String,
        detail: String,
        errorCode: String,
        extras: [String: Any] = [:]
    ) -> CanonicalToolResult {
        var payloadExtras = extras
        payloadExtras["error_code"] = errorCode
        payloadExtras["phone_ground"] = webPhoneGroundMetadata(status: "failed")
        let payload = failurePayload(
            error: detail,
            extras: payloadExtras
        )
        return CanonicalToolResult(
            success: false,
            summary: summary,
            detail: payload,
            errorCode: errorCode
        )
    }

    private static func webPhoneGroundMetadata(status: String) -> [String: Any] {
        [
            "version": "phoneground_v0",
            "evidence_type": PhoneGroundEvidenceType.web.rawValue,
            "answer_contract": PhoneGroundAnswerContract.groundedSources.rawValue,
            "freshness": PhoneGroundFreshnessRequirement.realtime.rawValue,
            "privacy": "public_web",
            "status": status
        ]
    }

    // MARK: - Utilities

    private static func stringArgument(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func stringArrayArgument(_ value: Any?) -> [String] {
        if let array = value as? [String] {
            return array.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let array = value as? [Any] {
            return array.compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            if let data = trimmed.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
                return array.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            return trimmed
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
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

    private static func httpsUpgradedURLIfNeeded(_ url: URL) -> URL {
        guard (url.scheme ?? "").lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }

    private static func hostName(from rawURL: String) -> String {
        guard let url = URL(string: rawURL),
              let host = url.host else {
            return ""
        }
        return host
    }

    private static func isHomepageLikeURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL) else { return false }
        let components = url.path
            .split(separator: "/")
            .filter { !$0.isEmpty }
        return components.count <= 1
    }

    private static func hasConcreteDataSignal(_ text: String) -> Bool {
        let patterns = [
            #"(?i)\d+(?:\.\d+)?\s?(?:℃|°c|°f|%|元|美元|人民币|港元|克|公斤|千克|盎司|g\b|kg\b|oz\b|usd\b|cny\b|hkd\b|km\b|公里|m/s\b|mm\b|hpa\b|kwh\b)"#,
            #"[$¥]\s?\d+(?:\.\d+)?"#,
            #"\d{1,4}\s?[/~-]\s?\d{1,4}\s?(?:℃|°c|°f|元|美元|usd|cny|hkd)"#,
            #"\d{4}[-/年]\d{1,2}[-/月]\d{1,2}日?"#,
            #"\d{1,2}月\d{1,2}日"#,
            #"(?i)\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2},?\s+\d{4}\b"#
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func looksLikeBoilerplatePage(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "please try another search",
            "popular searches",
            "get 50% off",
            "free sign up",
            "sign in free sign up",
            "open in app",
            "enable javascript",
            "please enable javascript",
            "access denied",
            "captcha",
            "temporarily unavailable",
            "oops, something went wrong",
            "something went wrong",
            "advertisement advertisement advertisement",
            "loading score",
            "載入比分中",
            "加载比分中",
            "載入中",
            "加载中",
            "著作權所有",
            "服務條款",
            "服务条款",
            "會員中心",
            "会员中心"
        ]
        if markers.contains(where: { lower.contains($0) }) {
            return true
        }

        let words = lower
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard words.count >= 80 else { return false }
        let uniqueRatio = Double(Set(words).count) / Double(words.count)
        let navigationSeparators = text.filter { $0 == "|" || $0 == "｜" }.count
        return uniqueRatio < 0.18 || navigationSeparators >= 18
    }

    private static func isDirectlyUsableSearchEvidence(_ evidence: [String: Any]) -> Bool {
        let snippet = (evidence["snippet"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !snippet.isEmpty else { return false }
        guard (evidence["is_homepage_like"] as? Bool) != true else { return false }
        guard (evidence["needs_fetch"] as? Bool) != true else { return false }
        guard (evidence["confidence"] as? String) != EvidenceConfidence.low.rawValue else { return false }
        guard (evidence["query_relevant"] as? Bool) != false else { return false }
        guard (evidence["freshness_ok"] as? Bool) != false else { return false }
        return true
    }

    private static func hasSufficientDirectEvidence(
        directCount: Int,
        needsFetchCount: Int,
        totalCount: Int
    ) -> Bool {
        guard directCount > 0 else { return false }

        // One isolated snippet among mostly fetch-required entries is too weak for current/live facts.
        // This is a coverage rule, not a domain keyword rule: if search evidence is mixed and thin,
        // the agent should read a source page before producing the final answer.
        if directCount == 1 {
            return needsFetchCount == 0 || totalCount == 1
        }

        // Direct answer should mean the returned snippets broadly cover the question.
        // If multiple top results still require reading the page, keep the agent in
        // evidence-gathering mode instead of letting a thin snippet decide the answer.
        return needsFetchCount <= 1 && directCount >= max(2, totalCount - 1)
    }

    private static func searchResultSort(_ lhs: SearchResult, _ rhs: SearchResult, query: String) -> Bool {
        let lhsRelevant = searchResultMatchesQuery(lhs, query: query)
        let rhsRelevant = searchResultMatchesQuery(rhs, query: query)
        if lhsRelevant != rhsRelevant { return lhsRelevant }

        // For time-sensitive queries, prefer the fresher result by parsed publish
        // date (graded), but only when the gap is meaningful — otherwise fall
        // through to evidence-quality priority.
        let window = WebFreshness.window(for: query)
        if window != .none {
            let lhsRecency = searchResultRecencyBoost(lhs, window: window)
            let rhsRecency = searchResultRecencyBoost(rhs, window: window)
            if abs(lhsRecency - rhsRecency) > 0.5 { return lhsRecency > rhsRecency }
        }

        let lhsRank = searchResultPriority(lhs)
        let rhsRank = searchResultPriority(rhs)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private static func searchResultRecencyBoost(_ result: SearchResult, window: WebFreshness.Window) -> Double {
        WebFreshness.recencyBoost(
            publishedAt: result.publishedAt ?? "\(result.title)\n\(result.snippet)",
            window: window,
            maxBoost: 100
        )
    }

    private static func freshnessFilteredSearchResults(
        _ results: [SearchResult],
        window: WebFreshness.Window,
        now: Date
    ) -> [SearchResult] {
        guard window != .none else { return results }
        return results.filter { searchResultFreshEnough($0, window: window, now: now) }
    }

    private static func hasEnoughFreshResults(
        _ results: [SearchResult],
        maxResults: Int,
        window: WebFreshness.Window
    ) -> Bool {
        let unique = uniqueResults(results)
        let fresh = freshnessFilteredSearchResults(unique, window: window, now: Date())
        return fresh.count >= maxResults
    }

    private static func searchResultFreshEnough(
        _ result: SearchResult,
        window: WebFreshness.Window,
        now: Date
    ) -> Bool {
        guard window != .none else { return true }
        // Do not discard undated snippets here: DuckDuckGo's day-filtered HTML
        // often omits dates even when the result is fresh. Dated stale results
        // are the dangerous case we can prove. Check both the provider timestamp
        // and source-visible dates from URL/title/snippet: RSS feeds can surface
        // old news with a fresh feed pubDate, while the article URL still carries
        // the real publication date.
        let providerDate = WebFreshness.parsePublishedDate(result.publishedAt, now: now)
        guard WebFreshness.isWithinWindow(date: providerDate, window: window, now: now) else {
            return false
        }
        let sourceDate = searchResultSourceDate(result, now: now)
        guard WebFreshness.isWithinWindow(date: sourceDate, window: window, now: now) else {
            return false
        }
        return true
    }

    private static func searchResultDate(_ result: SearchResult, now: Date) -> Date? {
        WebFreshness.parsePublishedDate(result.publishedAt, now: now)
            ?? searchResultSourceDate(result, now: now)
    }

    private static func searchResultSourceDate(_ result: SearchResult, now: Date) -> Date? {
        WebFreshness.parsePublishedDate("\(result.url)\n\(result.title)\n\(result.snippet)", now: now)
    }

    private static func searchResultPriority(_ result: SearchResult) -> Int {
        let evidence = result.dictionary(rank: 0)
        if evidence["directly_usable"] as? Bool == true { return 0 }
        if evidence["is_homepage_like"] as? Bool == true { return 4 }
        if evidence["has_concrete_data"] as? Bool == true { return 1 }
        if (result.publishedAt?.isEmpty == false) { return 2 }
        if !result.snippet.isEmpty { return 3 }
        return 5
    }

    private static func searchResultMatchesQuery(_ result: SearchResult, query: String) -> Bool {
        let concepts = significantQueryConcepts(query)
        guard !concepts.isEmpty else { return true }
        // Graded coverage with a soft floor: any genuine query-term overlap counts
        // as on-topic. The old "match 2 of N concepts" gate mislabeled real
        // results whenever a command word ("联网") inflated the concept count.
        return relevanceCoverage("\(result.title)\n\(result.snippet)", concepts: concepts) > 0
    }

    private static func significantQueryConcepts(_ query: String) -> [[String]] {
        var normalized = query.lowercased()
        let stopPhrases = [
            "帮我", "请问", "查一下", "搜一下", "搜索", "查询", "一下",
            "今天", "今日", "现在", "当前", "最近", "最新", "多少", "如何", "怎么样", "怎样",
            "的是", "的吗", "是吗", "是", "吗", "呢", "么",
            "the", "and", "for", "with", "to", "from", "what", "whats", "what's", "today", "current", "latest",
            "search", "look", "lookup", "find", "are", "is", "was", "were", "about", "please"
        ]
        for phrase in stopPhrases {
            normalized = normalized.replacingOccurrences(of: phrase, with: " ")
        }

        var concepts: [[String]] = []
        if let regex = try? NSRegularExpression(pattern: #"[\p{Han}]{2,}"#) {
            let nsRange = NSRange(normalized.startIndex..., in: normalized)
            for match in regex.matches(in: normalized, range: nsRange) {
                guard let range = Range(match.range, in: normalized) else { continue }
                let chunk = String(normalized[range])
                var alternatives = [chunk]
                let chars = Array(chunk)
                if chars.count > 2 {
                    alternatives.append(String(chars.prefix(2)))
                    alternatives.append(String(chars.suffix(2)))
                    for index in 0..<(chars.count - 1) {
                        alternatives.append(String(chars[index...(index + 1)]))
                    }
                }
                concepts.append(uniqueTerms(alternatives))
            }
        }

        concepts.append(contentsOf: normalized
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
            .filter { !isAllHan($0) }
            .map { [$0] })

        var seen = Set<String>()
        return concepts.compactMap { alternatives in
            let cleaned = uniqueTerms(alternatives).filter { $0.count >= 2 }
            guard !cleaned.isEmpty else { return nil }
            let key = cleaned.joined(separator: "|")
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return cleaned
        }
    }

    private static func uniqueTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { term in
            guard !seen.contains(term) else { return false }
            seen.insert(term)
            return true
        }
    }

    private static func isAllHan(_ text: String) -> Bool {
        text.range(of: #"^[\p{Han}]+$"#, options: .regularExpression) != nil
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

    private static func normalizedSearchQuery(_ query: String) -> String {
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

        value = normalizeWhitespace(value)
        return value.isEmpty ? query : value
    }

    private static func newsSearchQuery(_ query: String) -> String {
        query
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
