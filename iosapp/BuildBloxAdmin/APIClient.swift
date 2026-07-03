import Foundation

/// Target universe the dashboard is viewing.
enum Target: String, CaseIterable, Identifiable {
    case prod, dev
    var id: String { rawValue }
    var label: String { self == .prod ? "PROD" : "DEV" }
}

enum APIError: Error, LocalizedError {
    case unauthorized
    case http(Int)
    case transport(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:      return "Unauthorized — check your admin token."
        case .http(let code):    return "Server returned HTTP \(code)."
        case .transport(let e):  return "Network error: \(e.localizedDescription)"
        case .decoding(let e):   return "Couldn't read the response: \(e.localizedDescription)"
        }
    }
}

/// Thin async client over the BuildBlox worker. Every request carries the
/// X-Admin-Token header; the base URL is the deployed worker.
struct APIClient {
    static let baseURL = URL(string: "https://buildblox.gardinert4.workers.dev")!

    /// The admin token. In the app, load this from Keychain and inject it —
    /// don't hardcode it here.
    var token: String

    func get<T: Decodable>(
        _ path: String,
        target: Target = .prod,
        days: Int? = nil,
        query: [String: String] = [:],
        as type: T.Type = T.self
    ) async throws -> T {
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "target", value: target.rawValue)]
        if let days { items.append(URLQueryItem(name: "days", value: String(days))) }
        for (k, v) in query { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(token, forHTTPHeaderField: "X-Admin-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.transport(error)
        }
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 401 { throw APIError.unauthorized }
            guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}
