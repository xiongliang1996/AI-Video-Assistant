//
//  OpenAIService.swift
//  OpenAI：图片生成 / Whisper 语音识别 / TTS
//

import Foundation
import Alamofire

final class OpenAIService: VideoGeneratingService {
    let displayName = "OpenAI"

    private let config: AIConfig

    init(config: AIConfig) {
        self.config = config
    }

    private var baseURL: String {
        var url = config.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    private var authHeaders: HTTPHeaders {
        ["Authorization": "Bearer \(config.openAIKey)"]
    }

    // MARK: - 图像生成

    func generateImage(prompt: String, config gen: VideoGenerationConfig) async throws -> URL {
        guard !config.openAIKey.isEmpty else {
            throw AIError.missingAPIKey("OpenAI")
        }

        let fullPrompt = "\(prompt). \(gen.style.promptSuffix). \(gen.cameraMotion.promptSuffix)"

        let parameters: [String: Any] = [
            "model": config.imageModel,
            "prompt": fullPrompt,
            "n": 1,
            "size": mapSize(gen.resolution),
            "response_format": "url"
        ]

        let json = try await postJSON(path: "/images/generations", parameters: parameters)

        guard let data = json["data"] as? [[String: Any]],
              let first = data.first,
              let urlString = first["url"] as? String,
              let remote = URL(string: urlString) else {
            throw AIError.invalidResponse
        }

        return try await download(remote)
    }

    // MARK: - 语音识别

    func transcribe(audioURL: URL, language: String?) async throws -> String {
        guard !config.openAIKey.isEmpty else {
            throw AIError.missingAPIKey("OpenAI")
        }

        let endpoint = baseURL + "/audio/transcriptions"
        let model = config.whisperModel

        return try await withCheckedThrowingContinuation { continuation in
            AF.upload(
                multipartFormData: { form in
                    form.append(audioURL, withName: "file", fileName: audioURL.lastPathComponent, mimeType: "audio/m4a")
                    form.append(Data(model.utf8), withName: "model")
                    form.append(Data("srt".utf8), withName: "response_format")
                    if let language, !language.isEmpty {
                        form.append(Data(language.utf8), withName: "language")
                    }
                },
                to: endpoint,
                headers: authHeaders
            )
            .validate(statusCode: 200..<300)
            .responseString { response in
                switch response.result {
                case .success(let text):
                    continuation.resume(returning: text)
                case .failure(let error):
                    continuation.resume(throwing: AIError.requestFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - TTS

    func textToSpeech(text: String, voice: String, speed: Double) async throws -> URL {
        guard !config.openAIKey.isEmpty else {
            throw AIError.missingAPIKey("OpenAI")
        }

        let parameters: [String: Any] = [
            "model": "tts-1",
            "input": text,
            "voice": voice,
            "speed": max(0.25, min(4.0, speed)),
            "response_format": "mp3"
        ]

        let data = try await postRaw(path: "/audio/speech", parameters: parameters)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("openai-tts-\(UUID().uuidString).mp3")
        try data.write(to: file)
        return file
    }

    // MARK: - 网络辅助

    private func postJSON(path: String, parameters: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            AF.request(baseURL + path,
                       method: .post,
                       parameters: parameters,
                       encoding: JSONEncoding.default,
                       headers: authHeaders)
            .validate(statusCode: 200..<300)
            .responseJSON { response in
                switch response.result {
                case .success(let value):
                    guard let json = value as? [String: Any] else {
                        continuation.resume(throwing: AIError.invalidResponse)
                        return
                    }
                    continuation.resume(returning: json)
                case .failure(let error):
                    continuation.resume(throwing: AIError.requestFailed(error.localizedDescription))
                }
            }
        }
    }

    private func postRaw(path: String, parameters: [String: Any]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            AF.request(baseURL + path,
                       method: .post,
                       parameters: parameters,
                       encoding: JSONEncoding.default,
                       headers: authHeaders)
            .validate(statusCode: 200..<300)
            .responseData { response in
                switch response.result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: AIError.requestFailed(error.localizedDescription))
                }
            }
        }
    }

    private func download(_ remote: URL) async throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-media-\(UUID().uuidString).\(remote.pathExtension.isEmpty ? "png" : remote.pathExtension)")

        return try await withCheckedThrowingContinuation { continuation in
            AF.download(remote).responseData { response in
                switch response.result {
                case .success(let data):
                    do {
                        try data.write(to: file)
                        continuation.resume(returning: file)
                    } catch {
                        continuation.resume(throwing: AIError.downloadFailed(error.localizedDescription))
                    }
                case .failure:
                    continuation.resume(throwing: AIError.downloadFailed("网络下载失败"))
                }
            }
        }
    }

    private func mapSize(_ resolution: String) -> String {
        switch resolution {
        case "1920x1080": return "1792x1024"
        case "1024x1024": return "1024x1024"
        default: return "1024x1024"
        }
    }
}
