import Foundation

/// Asks GitHub whether a newer release exists.
///
/// Releases are the whole distribution mechanism, so this reads the same page a
/// person would: the latest release's tag. There is no update *installer* here
/// and deliberately so — an app that can replace its own binary is a much
/// larger security surface than one that opens a download page.
@MainActor
@Observable
final class UpdateCheck {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case failed
    }

    private(set) var state: State = .idle

    static let repository = "Team-Lunibee/Peninsula"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    static let sourcePage = URL(string: "https://github.com/\(repository)")!
    static let website = URL(string: "https://lunibee.kr")!

    var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func check() async {
        state = .checking

        guard let latest = await fetchLatestTag() else {
            state = .failed
            return
        }

        state = Self.isNewer(latest, than: installedVersion) ? .available(latest) : .upToDate
    }

    private func fetchLatestTag() async -> String? {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        // Ephemeral, like the lyrics fetch: an update check has no business
        // carrying this process's cookies or credentials to github.com.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                // 404 until the first release is published, and 403 once the
                // unauthenticated rate limit is hit. Neither is worth a log
                // line the user cannot act on.
                return nil
            }
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (payload?["tag_name"] as? String).map(Self.stripTagPrefix)
        } catch {
            return nil
        }
    }

    /// `v0.1.0` and `0.1.0` are the same release; tags are written both ways.
    static func stripTagPrefix(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Component-wise numeric comparison, so 0.10.0 sorts above 0.9.0 — which
    /// string comparison gets backwards, and which is exactly the version pair
    /// where a wrong answer stops telling anyone about updates.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let left = components(candidate)
        let right = components(installed)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        stripTagPrefix(version)
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
