//
//  AppLog.swift
//  统一日志：os_log 给 Console.app / `log stream` 看，文件给用户发过来
//
//  为什么两个都要：os_log 按进程存、会过期，用户把 app 关了再问你「昨天导出失败」，
//  那段日志可能已经查不到了；文件留在 ~/Library/Logs 里，出问题时让对方把文件发来就行。
//

import Foundation
import AppKit
import os

enum AppLog {
    static let subsystem = "com.xiongliang.aivideoassistant"

    enum Category: String, CaseIterable {
        case app
        case export
        case media
        case ai
        case project

        var logger: Logger { Logger(subsystem: AppLog.subsystem, category: rawValue) }
    }

    // MARK: - 写日志

    static func info(_ category: Category, _ message: String) {
        category.logger.info("\(message, privacy: .public)")
        LogFile.shared.write("[\(category.rawValue)] \(message)")
    }

    static func warning(_ category: Category, _ message: String) {
        category.logger.warning("\(message, privacy: .public)")
        LogFile.shared.write("[\(category.rawValue)] ⚠️ \(message)")
    }

    static func error(_ category: Category, _ message: String) {
        category.logger.error("\(message, privacy: .public)")
        LogFile.shared.write("[\(category.rawValue)] ❌ \(message)")
    }

    // MARK: - 给界面用

    static var fileURL: URL { LogFile.shared.fileURL }

    /// 在访达里定位日志文件（文件还不存在时先建一个空文件）
    static func revealLogFile() {
        LogFile.shared.flush()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

/// 落盘的那一份。写操作串行、超限就滚动一次
final class LogFile {
    static let shared = LogFile()

    private let queue = DispatchQueue(label: "\(AppLog.subsystem).log")
    private let directory: URL
    private let maxBytes: Int

    var fileURL: URL { directory.appendingPathComponent("app.log") }

    /// - Parameters:
    ///   - directory: 默认 `~/Library/Logs/AIVideoAssistant`，测试可以指到临时目录
    ///   - maxBytes: 超过就滚成 app.log.1（只留一份旧的，够查最近一次问题）
    ///
    /// 优先级：显式传参 > 环境变量 `AIVA_LOG_DIR` > 默认路径。
    /// 环境变量是给测试用的——把 `LogFile.shared` 引到临时目录，才好断言「某处真的写了日志」。
    init(directory: URL? = nil, maxBytes: Int = 512 * 1024) {
        if let directory {
            self.directory = directory
        } else if let env = ProcessInfo.processInfo.environment["AIVA_LOG_DIR"], !env.isEmpty {
            self.directory = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            self.directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/AIVideoAssistant", isDirectory: true)
        }
        self.maxBytes = maxBytes
    }

    func write(_ line: String) {
        queue.async { self.append(line) }
    }

    /// 等队列里排着的写操作都落地（测试和「打开日志」前用）
    func flush() {
        queue.sync {}
    }

    private func append(_ line: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        if let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? Int,
           size > maxBytes {
            let backup = directory.appendingPathComponent("app.log.1")
            try? manager.removeItem(at: backup)
            try? manager.moveItem(at: fileURL, to: backup)
        }

        let text = "\(Self.stamp()) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        // 不锁死 locale / 日历会出洋相：系统切成佛历时这行会写成 2569 年，
        // 拿去对时间线根本对不上（实测踩到过）
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static func stamp() -> String {
        formatter.string(from: Date())
    }
}
