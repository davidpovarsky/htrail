import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum RealtimeURLSession {
    static func configuration(for url: URL) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15

        if url.isLoopbackRealtimeEndpoint {
            configuration.connectionProxyDictionary = [:]
            configuration.waitsForConnectivity = false
        }

        return configuration
    }

    static func session(for url: URL) -> URLSession {
        URLSession(configuration: configuration(for: url))
    }
}

private extension URL {
    var isLoopbackRealtimeEndpoint: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
