//
//  TTSManager.swift
//  多引擎语音合成：OpenAI / Azure / 讯飞
//

import Foundation
import Alamofire
import AVFoundation

final class TTSManager {
    static let shared = TTSManager()

    private init() {}

    // MARK: - 音色表

    func voices(for provider: TTSProvider) -> [TTSVoice] {
        switch provider {
        case .openAI:
            return [
                TTSVoice(id: "nova", name: "Nova", subtitle: "女声 · 明亮", hue: 265),
                TTSVoice(id: "shimmer", name: "Shimmer", subtitle: "女声 · 温柔", hue: 320),
                TTSVoice(id: "alloy", name: "Alloy", subtitle: "中性 · 平稳", hue: 200),
                TTSVoice(id: "onyx", name: "Onyx", subtitle: "男声 · 低沉", hue: 220),
                TTSVoice(id: "echo", name: "Echo", subtitle: "男声 · 清晰", hue: 180),
                TTSVoice(id: "fable", name: "Fable", subtitle: "中性 · 叙事", hue: 30)
            ]
        case .azure:
            return [
                TTSVoice(id: "zh-CN-XiaoxiaoNeural", name: "晓晓", subtitle: "女声 · 温柔", hue: 265),
                TTSVoice(id: "zh-CN-YunxiNeural", name: "云希", subtitle: "男声 · 沉稳", hue: 200),
                TTSVoice(id: "zh-CN-XiaohanNeural", name: "晓涵", subtitle: "女声 · 知性", hue: 320),
                TTSVoice(id: "zh-CN-YunyangNeural", name: "云扬", subtitle: "男声 · 播音", hue: 220),
                TTSVoice(id: "zh-CN-XiaomoNeural", name: "晓墨", subtitle: "女声 · 活泼", hue: 20),
                TTSVoice(id: "en-US-JennyNeural", name: "Jenny", subtitle: "女声 · 英文", hue: 170)
            ]
        case .xfyun:
            return [
                TTSVoice(id: "xiaoyan", name: "小燕", subtitle: "女声 · 亲和", hue: 265),
                TTSVoice(id: "aisjiuxu", name: "许久", subtitle: "男声 · 沉稳", hue: 200),
                TTSVoice(id: "aisxunying", name: "讯莹", subtitle: "女声 · 温柔", hue: 320),
                TTSVoice(id: "aisbabyxu", name: "Babyxu", subtitle: "童声 · 可爱", hue: 30)
            ]
        }
    }

    // MARK: - 合成入口

    func synthesize(text: String,
                    provider: TTSProvider,
                    voice: String,
                    speed: Double,
                    config: AIConfig) async throws -> TTSResult {
        switch provider {
        case .openAI:
            return try await openAI(text: text, voice: voice, speed: speed, config: config)
        case .azure:
            return try await azure(text: text, voice: voice, speed: speed, config: config)
        case .xfyun:
            return try await xfyun(text: text, voice: voice, speed: speed, config: config)
        }
    }

    // MARK: - OpenAI

    private func openAI(text: String, voice: String, speed: Double, config: AIConfig) async throws -> TTSResult {
        let service = OpenAIService(config: config)
        let url = try await service.textToSpeech(text: text, voice: voice, speed: speed)
        let duration = await Self.duration(of: url)
        return TTSResult(audioURL: url, provider: .openAI, voice: voice, duration: duration)
    }

    // MARK: - Azure

    private func azure(text: String, voice: String, speed: Double, config: AIConfig) async throws -> TTSResult {
        guard !config.azureKey.isEmpty else { throw AIError.missingAPIKey("Azure") }

        let region = config.azureRegion.isEmpty ? "eastasia" : config.azureRegion
        guard let url = URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1") else {
            throw AIError.requestFailed("Azure 区域配置无效")
        }

        let rate = Int((speed - 1.0) * 100)
        let sign = rate >= 0 ? "+" : ""
        let ssml = """
        <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>
          <voice name='\(voice)'>
            <prosody rate='\(sign)\(rate)%'>\(escapeXML(text))</prosody>
          </voice>
        </speak>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.azureKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("audio-16khz-128kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("AIVideoAssistant", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(ssml.utf8)

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            AF.request(request)
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

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("azure-tts-\(UUID().uuidString).mp3")
        try data.write(to: file)
        let duration = await Self.duration(of: file)
        return TTSResult(audioURL: file, provider: .azure, voice: voice, duration: duration)
    }

    // MARK: - 讯飞

    private func xfyun(text: String, voice: String, speed: Double, config: AIConfig) async throws -> TTSResult {
        guard !config.xfyunAppID.isEmpty, !config.xfyunAPIKey.isEmpty else {
            throw AIError.missingAPIKey("讯飞")
        }

        // 讯飞在线合成走 WebSocket + HMAC 签名，此处为 HTTP 占位通道
        guard let url = URL(string: "https://tts-api.xfyun.cn/v2/tts") else {
            throw AIError.requestFailed("讯飞接口地址无效")
        }

        let parameters: [String: Any] = [
            "common": ["app_id": config.xfyunAppID],
            "business": [
                "aue": "lame",
                "sfl": 1,
                "vcn": voice,
                "speed": Int(speed * 50),
                "volume": 50,
                "pitch": 50,
                "tte": "UTF8"
            ],
            "data": [
                "status": 2,
                "text": Data(text.utf8).base64EncodedString()
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.xfyunAPIKey, forHTTPHeaderField: "X-Api-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            AF.request(request)
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

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("xfyun-tts-\(UUID().uuidString).mp3")
        try data.write(to: file)
        let duration = await Self.duration(of: file)
        return TTSResult(audioURL: file, provider: .xfyun, voice: voice, duration: duration)
    }

    // MARK: - 工具

    private func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(d)
        return seconds.isFinite ? seconds : 0
    }
}
