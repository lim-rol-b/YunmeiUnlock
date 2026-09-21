import CryptoKit
import Foundation

struct YunmeiSchool: Identifiable, Equatable, Sendable {
    let number: String
    let name: String
    let serverURL: URL
    let token: String

    var id: String { number }
}

struct YunmeiLoginContext: Sendable {
    let userID: String
    let schools: [YunmeiSchool]
}

enum YunmeiAPIError: LocalizedError {
    case invalidResponse
    case server(String)
    case noSchool
    case noDoor
    case invalidSchoolURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "云莓服务器返回了无法识别的数据"
        case .server(let message):
            return message
        case .noSchool:
            return "该账号没有可用学校"
        case .noDoor:
            return "该学校没有可用门锁"
        case .invalidSchoolURL(let value):
            return "学校服务器地址无效：\(value)"
        }
    }
}

struct YunmeiAPIClient: Sendable {
    private let baseURL = URL(string: "https://base.yunmeitech.com/")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func login(username: String, password: String) async throws -> YunmeiLoginContext {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordHash = Self.md5(password)
        let loginJSON = try await post(
            path: "/login",
            baseURL: baseURL,
            form: ["userName": normalizedUsername, "userPwd": passwordHash]
        )

        guard let login = loginJSON as? [String: Any] else {
            throw YunmeiAPIError.invalidResponse
        }
        if Self.bool(login["success"]) == false {
            throw YunmeiAPIError.server(Self.string(login["msg"]) ?? "账号或密码错误")
        }
        guard let object = login["o"] as? [String: Any],
              let userID = Self.string(object["userId"]),
              let token = Self.string(object["token"]) else {
            throw YunmeiAPIError.invalidResponse
        }

        let headers = Self.authorizationHeaders(token: token, userID: userID)
        let schoolJSON = try await post(
            path: "/userschool/getbyuserid",
            baseURL: baseURL,
            form: ["userId": userID],
            headers: headers
        )
        guard let schoolItems = schoolJSON as? [[String: Any]] else {
            throw YunmeiAPIError.invalidResponse
        }

        let schools = try schoolItems.compactMap { item -> YunmeiSchool? in
            guard let number = Self.string(item["schoolNo"]),
                  let schoolToken = Self.string(item["token"]),
                  let school = item["school"] as? [String: Any],
                  let name = Self.string(school["schoolName"]),
                  let urlString = Self.string(school["serverUrl"]) else {
                return nil
            }
            guard let serverURL = Self.normalizedURL(urlString) else {
                throw YunmeiAPIError.invalidSchoolURL(urlString)
            }
            return YunmeiSchool(number: number, name: name, serverURL: serverURL, token: schoolToken)
        }
        guard !schools.isEmpty else { throw YunmeiAPIError.noSchool }
        return YunmeiLoginContext(userID: userID, schools: schools)
    }

    func doors(for school: YunmeiSchool, userID: String) async throws -> [DoorConfiguration] {
        let json = try await post(
            path: "/dormuser/getuserlock",
            baseURL: school.serverURL,
            form: ["schoolNo": school.number, "userId": userID],
            headers: Self.authorizationHeaders(token: school.token, userID: userID)
        )
        guard let items = json as? [[String: Any]] else {
            throw YunmeiAPIError.invalidResponse
        }

        let doors = items.compactMap { item -> DoorConfiguration? in
            guard let secret = Self.string(item["lockSecret"]),
                  let characteristicUUID = Self.string(item["lockCharacterUuid"]),
                  let serviceUUID = Self.string(item["lockServiceUuid"]),
                  let lockNumber = Self.string(item["lockNo"]) else {
                return nil
            }
            let building = Self.string(item["buildName"]) ?? "门禁"
            let dormitory = Self.string(item["dormNo"]) ?? lockNumber
            return DoorConfiguration(
                name: "\(building)-\(dormitory)",
                schoolNumber: school.number,
                lockNumber: lockNumber,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                secret: secret
            )
        }
        guard !doors.isEmpty else { throw YunmeiAPIError.noDoor }
        return doors
    }

    private func post(
        path: String,
        baseURL: URL,
        form: [String: String],
        headers: [String: String] = [:]
    ) async throws -> Any {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw YunmeiAPIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = Self.formBody(form)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw YunmeiAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = Self.serverMessage(from: data) ?? "服务器请求失败（HTTP \(httpResponse.statusCode)）"
            throw YunmeiAPIError.server(message)
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw YunmeiAPIError.invalidResponse
        }
    }

    private static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func formBody(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._*"))
        let string = values
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return Data(string.utf8)
    }

    private static func authorizationHeaders(token: String, userID: String) -> [String: String] {
        ["token_data": token, "token_userId": userID, "tokenUserId": userID]
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.boolValue
        case let string as String: return ["true", "1"].contains(string.lowercased())
        default: return nil
        }
    }

    private static func normalizedURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            return nil
        }
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    private static func serverMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return string(object["msg"])
    }
}
