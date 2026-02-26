import Foundation
import CFNetwork
import HuggingFace

enum MLXModelDownloadSupport {
    private static let modelEntryAllowedExtensions: Set<String> = ["safetensors", "json", "txt", "wav"]
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    enum DownloadValidationError: LocalizedError {
        case missingFiles
        case sizeMismatch(expected: Int64, actual: Int64)
        case emptyFileList

        var errorDescription: String? {
            switch self {
            case .missingFiles:
                return "Downloaded files are incomplete."
            case .sizeMismatch(let expected, let actual):
                let expectedText = byteFormatter.string(fromByteCount: expected)
                let actualText = byteFormatter.string(fromByteCount: actual)
                return "Download incomplete (expected ~\(expectedText), got \(actualText))."
            case .emptyFileList:
                return "No downloadable files were found for this model."
            }
        }
    }

    enum DownloadNetworkError: LocalizedError {
        case mirrorRejected(statusCode: Int)
        case modelUnavailable(repo: String, statusCode: Int)
        case metadataRequestFailed(statusCode: Int)
        case invalidServerResponse

        var errorDescription: String? {
            switch self {
            case .mirrorRejected(let statusCode):
                return "China mirror rejected request (HTTP \(statusCode))."
            case .modelUnavailable(let repo, let statusCode):
                return "Model repository unavailable (\(repo), HTTP \(statusCode))."
            case .metadataRequestFailed(let statusCode):
                return "Model metadata request failed (HTTP \(statusCode))."
            case .invalidServerResponse:
                return "Invalid response from model server."
            }
        }
    }

    struct ModelFileEntry: Hashable {
        let path: String
        let size: Int64?
    }

    static func makeDownloadSession(for baseURL: URL) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = false

        if isMirrorHost(baseURL) {
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: false,
                kCFNetworkProxiesHTTPSEnable as String: false,
                kCFNetworkProxiesSOCKSEnable as String: false,
            ]
        }

        return URLSession(configuration: configuration)
    }

    static func makeHubClient(
        session: URLSession,
        baseURL: URL,
        cache: HubCache,
        token: String?,
        userAgent: String
    ) -> HubClient {
        if let token, !token.isEmpty {
            return HubClient(
                session: session,
                host: baseURL,
                userAgent: userAgent,
                bearerToken: token,
                cache: cache
            )
        }
        return HubClient(
            session: session,
            host: baseURL,
            userAgent: userAgent,
            cache: cache
        )
    }

    static func fetchModelEntries(
        repo: String,
        baseURL: URL,
        session: URLSession,
        userAgent: String
    ) async throws -> [ModelFileEntry] {
        guard let encoded = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw URLError(.badURL)
        }
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/models/\(encoded)/tree/main?recursive=1")
        else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadNetworkError.invalidServerResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            if isMirrorHost(baseURL), [401, 403].contains(httpResponse.statusCode) {
                throw DownloadNetworkError.mirrorRejected(statusCode: httpResponse.statusCode)
            }
            if [401, 404].contains(httpResponse.statusCode) {
                throw DownloadNetworkError.modelUnavailable(repo: repo, statusCode: httpResponse.statusCode)
            }
            throw DownloadNetworkError.metadataRequestFailed(statusCode: httpResponse.statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return json.compactMap { item in
            guard (item["type"] as? String) == "file" else { return nil }
            let path = (item["path"] as? String) ?? ""
            let ext = path.split(separator: ".").last.map(String.init) ?? ""
            guard modelEntryAllowedExtensions.contains(ext.lowercased()) else { return nil }
            let size: Int64?
            if let raw = item["size"] as? Int {
                size = Int64(raw)
            } else if let raw = item["size"] as? Int64 {
                size = raw
            } else {
                size = nil
            }
            return ModelFileEntry(path: path, size: size)
        }
    }

    static func fetchModelSizeInfo(
        repo: String,
        baseURL: URL,
        userAgent: String,
        byteFormatter: ByteCountFormatter
    ) async throws -> (bytes: Int64, text: String) {
        let entries = try await fetchModelEntries(
            repo: repo,
            baseURL: baseURL,
            session: makeDownloadSession(for: baseURL),
            userAgent: userAgent
        )
        let total = entries.reduce(Int64(0)) { partial, entry in
            partial + max(entry.size ?? 0, 0)
        }

        guard total > 0 else { return (0, "Unknown") }
        return (total, byteFormatter.string(fromByteCount: total))
    }

    static func validateDownloadedModel(
        at url: URL,
        sizeState: MLXModelManager.ModelSizeState,
        downloadSizeTolerance: Double,
        fileManager: FileManager
    ) throws {
        let files = allFiles(at: url, fileManager: fileManager)
        let hasWeights = files.contains { file in
            guard file.pathExtension.lowercased() == "safetensors" else { return false }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size > 0
        }
        let configValid = files.contains { file in
            guard file.lastPathComponent.lowercased() == "config.json" else { return false }
            guard let data = try? Data(contentsOf: file) else { return false }
            return (try? JSONSerialization.jsonObject(with: data)) != nil
        }

        guard hasWeights, configValid else {
            throw DownloadValidationError.missingFiles
        }

        if case .ready(let expectedBytes, _) = sizeState,
           expectedBytes > 0,
           let actualBytesRaw = try? fileManager.allocatedSizeOfDirectory(at: url)
        {
            let actualBytes = Int64(actualBytesRaw)
            let minimumBytes = Int64(Double(expectedBytes) * downloadSizeTolerance)
            if actualBytes < minimumBytes {
                throw DownloadValidationError.sizeMismatch(expected: expectedBytes, actual: actualBytes)
            }
        }
    }

    static func clearDirectory(at url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for item in contents {
                try? fileManager.removeItem(at: item)
            }
            try fileManager.removeItem(at: url)
        }
    }

    static func isModelDirectoryValid(_ directory: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else { return false }

        if let topLevelItems = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
            let malformed = topLevelItems.contains { item in
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDirectory else { return false }
                let ext = item.pathExtension.lowercased()
                return ext == "json" || ext == "safetensors" || ext == "txt" || ext == "wav"
            }
            if malformed {
                return false
            }
        }

        let files = allFiles(at: directory, fileManager: fileManager)
        let hasWeights = files.contains { file in
            guard file.pathExtension.lowercased() == "safetensors" else { return false }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size > 0
        }
        let rootConfig = directory.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: rootConfig.path),
              let rootConfigData = try? Data(contentsOf: rootConfig),
              (try? JSONSerialization.jsonObject(with: rootConfigData)) != nil
        else {
            return false
        }

        return hasWeights
    }

    static func isMirrorHost(_ url: URL) -> Bool {
        url.host?.contains("hf-mirror.com") == true
    }

    private static func allFiles(at root: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            if isRegular {
                files.append(fileURL)
            }
        }
        return files
    }
}
