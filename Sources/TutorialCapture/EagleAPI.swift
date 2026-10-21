import Foundation

struct EagleFolderNode: Decodable, Identifiable {
    let id: String
    let name: String
    let children: [EagleFolderNode]?
}

struct EagleFolderOption: Identifiable {
    let id: String
    let name: String
    let path: String
    let depth: Int
}

enum EagleAPI {
    private static let baseURL = URL(string: "http://127.0.0.1:41595")!

    static func folders() async throws -> [EagleFolderOption] {
        let data = try await request(path: "/api/folder/list")
        let envelope = try JSONDecoder().decode(FolderEnvelope.self, from: data)
        return flatten(envelope.data)
    }

    static func itemNames(folderID: String) async throws -> [String] {
        var names: [String] = []
        var offset = 0
        let limit = 1000
        while true {
            var components = URLComponents(url: baseURL.appendingPathComponent("api/item/list"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "folders", value: folderID),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset))
            ]
            guard let url = components.url else { throw EagleError.invalidURL }
            let data = try await request(url: url)
            let envelope = try JSONDecoder().decode(ItemEnvelope.self, from: data)
            names.append(contentsOf: envelope.data.map(\.name))
            guard envelope.data.count == limit else { break }
            offset += limit
        }
        return names
    }

    @discardableResult
    static func importFile(at fileURL: URL, name: String, folderID: String, annotation: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/item/addFromPath"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "path": fileURL.path,
            "name": name,
            "folderId": folderID,
            "annotation": annotation
        ])
        let data = try await perform(request)
        let envelope = try JSONDecoder().decode(StatusEnvelope.self, from: data)
        guard envelope.status == "success" else { throw EagleError.rejected(envelope.message ?? "Eagle 没有接受此素材") }
        if let itemID = envelope.data, !itemID.isEmpty {
            try await waitForItem(id: itemID, folderID: folderID)
            return itemID
        }
        for _ in 0..<20 {
            if try await itemNames(folderID: folderID).contains(name) { return name }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw EagleError.rejected("Eagle 接受了导入请求，但目标文件夹暂时查不到“\(name)”。原始素材已保留，请在 Eagle 中刷新后检查。")
    }

    private static func waitForItem(id: String, folderID: String) async throws {
        var lastError: Error?
        for _ in 0..<20 {
            do {
                var components = URLComponents(url: baseURL.appendingPathComponent("api/item/info"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "id", value: id)]
                guard let url = components.url else { throw EagleError.invalidURL }
                let data = try await request(url: url)
                let envelope = try JSONDecoder().decode(ItemInfoEnvelope.self, from: data)
                guard envelope.status == "success", let item = envelope.data else {
                    throw EagleError.rejected("Eagle 已返回素材编号，但暂时查不到该素材。")
                }
                if item.folders.contains(folderID) { return }
                throw EagleError.rejected("素材已进入 Eagle，但没有出现在所选文件夹中。")
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw lastError ?? EagleError.rejected("无法确认素材是否已进入 Eagle。")
    }

    private static func request(path: String) async throws -> Data {
        try await request(url: baseURL.appendingPathComponent(String(path.dropFirst())))
    }

    private static func request(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        return try await perform(request)
    }

    private static func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw EagleError.httpFailure((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            return data
        } catch let error as EagleError {
            throw error
        } catch {
            throw EagleError.unavailable(error.localizedDescription)
        }
    }

    private static func flatten(_ folders: [EagleFolderNode], prefix: String = "", depth: Int = 0) -> [EagleFolderOption] {
        folders.flatMap { folder in
            let path = prefix.isEmpty ? folder.name : "\(prefix) / \(folder.name)"
            let current = EagleFolderOption(id: folder.id, name: folder.name, path: path, depth: depth)
            return [current] + flatten(folder.children ?? [], prefix: path, depth: depth + 1)
        }
    }

    private struct FolderEnvelope: Decodable {
        let status: String
        let data: [EagleFolderNode]
    }

    private struct ItemEnvelope: Decodable {
        let status: String
        let data: [EagleItem]
    }

    private struct EagleItem: Decodable {
        let name: String
    }

    private struct StatusEnvelope: Decodable {
        let status: String
        let message: String?
        let data: String?
    }

    private struct ItemInfoEnvelope: Decodable {
        let status: String
        let data: ItemInfo?
    }

    private struct ItemInfo: Decodable {
        let folders: [String]
    }

    enum EagleError: LocalizedError {
        case invalidURL
        case httpFailure(Int)
        case unavailable(String)
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Eagle 接口地址无效。"
            case .httpFailure(let code): "Eagle 接口返回 HTTP \(code)。"
            case .unavailable(let reason): "无法连接 Eagle。请先打开 Eagle，再重试。\n\(reason)"
            case .rejected(let reason): reason
            }
        }
    }
}
