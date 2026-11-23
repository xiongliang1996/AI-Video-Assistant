//
//  AIServiceProtocol.swift
//  AI 服务抽象层
//

import Foundation

// MARK: - AI 错误

enum AIError: LocalizedError {
    case missingAPIKey(String)
    case requestFailed(String)
    case invalidResponse
    case generationFailed(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let name): return "缺少 \(name) 的 API Key，请在设置中配置"
        case .requestFailed(let msg): return "请求失败：\(msg)"
        case .invalidResponse: return "服务器返回了无法解析的内容"
        case .generationFailed(let msg): return "生成失败：\(msg)"
        case .downloadFailed(let msg): return "文件下载失败：\(msg)"
        }
    }
}

// MARK: - 视频生成

struct VideoGenerationConfig {
    var duration: Int = 5
    var resolution: String = "1280x720"
    var fps: Int = 24
    var style: VideoStyle = .realistic
    var cameraMotion: CameraMotion = .fixed
    var negativePrompt: String = ""
}

enum VideoStyle: String, CaseIterable, Hashable {
    case realistic = "写实"
    case cinematic = "电影感"
    case anime = "动漫"
    case watercolor = "水彩"
    case pixel = "像素风"
    case abstract = "抽象"

    var promptSuffix: String {
        switch self {
        case .realistic: return "photorealistic, natural lighting, high detail"
        case .cinematic: return "cinematic lighting, shallow depth of field, film grain"
        case .anime: return "anime style, clean line art, vivid colors"
        case .watercolor: return "watercolor painting, soft edges, paper texture"
        case .pixel: return "pixel art, 16-bit style, limited palette"
        case .abstract: return "abstract composition, bold shapes, gradient colors"
        }
    }
}

enum CameraMotion: String, CaseIterable, Hashable {
    case fixed = "固定"
    case pushIn = "推进"
    case pullOut = "拉远"
    case pan = "摇移"

    var promptSuffix: String {
        switch self {
        case .fixed: return "static camera, locked off shot"
        case .pushIn: return "slow dolly in, camera pushes forward"
        case .pullOut: return "slow dolly out, camera pulls back"
        case .pan: return "smooth camera pan"
        }
    }
}

protocol VideoGeneratingService {
    var displayName: String { get }
    func generateImage(prompt: String, config: VideoGenerationConfig) async throws -> URL
}

// MARK: - TTS

struct TTSVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let hue: Double
}

struct TTSResult {
    let audioURL: URL
    let provider: TTSProvider
    let voice: String
    let duration: Double
}
