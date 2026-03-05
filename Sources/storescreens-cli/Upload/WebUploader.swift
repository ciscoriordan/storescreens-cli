import Foundation

struct WebUploader {
    let baseURL: String
    let logger: Logger

    init(baseURL: String = "https://storescreens.app", logger: Logger) {
        self.baseURL = baseURL
        self.logger = logger
    }

    struct InitiateResponse: Decodable {
        let status: String
        let upload_token: String?
        let error: String?
    }

    struct UploadResponse: Decodable {
        let project_id: Int?
        let url: String?
        let error: String?
    }

    // MARK: - Initiate upload session

    func initiate(email: String) async throws -> InitiateResponse {
        let url = URL(string: "\(baseURL)/api/v1/upload_sessions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["email": email])

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        guard (200...299).contains(httpResponse.statusCode) else {
            if let body = try? JSONDecoder().decode(InitiateResponse.self, from: data), let error = body.error {
                throw UploadError.serverError(error)
            }
            throw UploadError.serverError("Server returned status \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(InitiateResponse.self, from: data)
    }

    // MARK: - Verify code for existing users

    func verify(email: String, code: String) async throws -> InitiateResponse {
        let url = URL(string: "\(baseURL)/api/v1/upload_sessions/verify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["email": email, "code": code])

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        guard (200...299).contains(httpResponse.statusCode) else {
            if let body = try? JSONDecoder().decode(InitiateResponse.self, from: data), let error = body.error {
                throw UploadError.serverError(error)
            }
            throw UploadError.serverError("Invalid or expired code")
        }

        return try JSONDecoder().decode(InitiateResponse.self, from: data)
    }

    // MARK: - Upload screenshots

    func upload(token: String, manifest: CaptureManifest, outputDir: URL) async throws -> UploadResponse {
        let boundary = UUID().uuidString
        let url = URL(string: "\(baseURL)/api/v1/uploads")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Add manifest JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestJSON = try encoder.encode(manifest)
        body.appendMultipart(boundary: boundary, name: "manifest", value: String(data: manifestJSON, encoding: .utf8)!)

        // Add screenshot files
        for device in manifest.devices {
            for screenshot in device.screenshots {
                let filePath = outputDir.appendingPathComponent(screenshot.filename)
                guard FileManager.default.fileExists(atPath: filePath.path) else { continue }
                let fileData = try Data(contentsOf: filePath)
                body.appendMultipartFile(boundary: boundary, name: "screenshots[]", filename: screenshot.filename, mimeType: "image/png", data: fileData)
            }
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        guard (200...299).contains(httpResponse.statusCode) else {
            if let respBody = try? JSONDecoder().decode(UploadResponse.self, from: data), let error = respBody.error {
                throw UploadError.serverError(error)
            }
            throw UploadError.serverError("Upload failed with status \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(UploadResponse.self, from: data)
    }
}

// MARK: - Error

enum UploadError: LocalizedError {
    case serverError(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .serverError(let message): return message
        case .cancelled: return "Upload cancelled"
        }
    }
}

// MARK: - Data helpers for multipart

extension Data {
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(boundary: String, name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
