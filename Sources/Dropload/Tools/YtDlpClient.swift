//
//  YtDlpClient.swift
//  Dropload
//
//  Runs yt-dlp as a child process. Never blocks the main actor: the droplet
//  runs inside Droppy's process, on Droppy's main thread.
//

import Foundation

/// What a running download reports.
public enum DownloadEvent: Equatable, Sendable {
    /// 0...1, with speed and ETA as yt-dlp formats them.
    case progress(fraction: Double, speed: String?, eta: String?)
    /// yt-dlp moved on to merging, extracting or remuxing.
    case postProcessing
    /// The final file.
    case finished(URL)
}

public enum YtDlpError: Error, Equatable, Sendable {
    case toolsNotReady
    case unsupportedURL
    case processFailed(exitCode: Int32, message: String)
    case cancelled
}

@MainActor
public protocol YtDlpRunning: AnyObject {
    /// `yt-dlp -J --no-playlist --skip-download <url>`, decoded.
    func fetchInfo(for url: URL) async throws -> MediaInfo

    /// Downloads `url` into `folder`. Cancelling the consuming task
    /// terminates the process.
    func download(_ url: URL, options: DownloadOptions, into folder: URL) -> AsyncThrowingStream<DownloadEvent, Error>

    /// Terminates every child process. Called from `deactivate()`.
    func cancelAll()
}

/// The real implementation.
///
/// TODO(T2): implement with `Process`.
/// - Always pass `--no-playlist`, `--ffmpeg-location <ffmpeg>` when known,
///   `--newline`, `--no-colors`, and a machine-readable
///   `--progress-template "download:dropload %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"`
///   plus `--print after_move:filepath` to learn the final path. Parse
///   `ProgressParser` lines, not yt-dlp's human output.
/// - Output template: `<folder>/%(title).200B [%(id)s].%(ext)s`.
/// - Read pipes off the main actor; deliver events on it.
/// - Keep every `Process` so `cancelAll()` can terminate them.
/// - `fetchInfo` maps a Generic extractor with no formats to `.unsupportedURL`.
@MainActor
public final class YtDlpClient: YtDlpRunning {
    private let tools: @MainActor () -> ToolStatus
    private let log: @MainActor (String) -> Void

    public init(tools: @escaping @MainActor () -> ToolStatus, log: @escaping @MainActor (String) -> Void) {
        self.tools = tools
        self.log = log
    }

    public func fetchInfo(for url: URL) async throws -> MediaInfo {
        log("YtDlpClient.fetchInfo not implemented yet")
        throw YtDlpError.toolsNotReady
    }

    public func download(_ url: URL, options: DownloadOptions, into folder: URL) -> AsyncThrowingStream<DownloadEvent, Error> {
        log("YtDlpClient.download not implemented yet")
        return AsyncThrowingStream { $0.finish(throwing: YtDlpError.toolsNotReady) }
    }

    public func cancelAll() {}
}

/// Turns one `--progress-template` line into an event.
///
/// TODO(T2): implement and test. Input looks like
/// `dropload  42.3%|  3.10MiB/s|00:12`; return `nil` for any other line.
public enum ProgressParser {
    public static let prefix = "dropload "

    public static func parse(_ line: String) -> DownloadEvent? {
        nil
    }
}
