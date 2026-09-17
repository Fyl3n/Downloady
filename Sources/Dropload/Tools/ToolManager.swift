//
//  ToolManager.swift
//  Dropload
//
//  Where yt-dlp and ffmpeg come from.
//
//  yt-dlp: always the droplet's own copy, downloaded on first run into
//  `host.environment.containerDirectory/tools/`, never into the bundle
//  (Droppy refuses a bundle whose files changed after approval).
//  ffmpeg: a system copy when there is one, otherwise a downloaded static
//  build in the same folder.
//

import Foundation

/// A located executable and where it came from.
public struct ToolLocation: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// Downloaded by the droplet into its container.
        case managed
        /// Found on the system (Homebrew, /usr/local, PATH).
        case system
        /// A path the user set in Settings.
        case custom
    }

    public let url: URL
    public let source: Source
    public let version: String?

    public init(url: URL, source: Source, version: String?) {
        self.url = url
        self.source = source
        self.version = version
    }
}

/// What the widget needs to know before it can offer a download.
public enum ToolStatus: Equatable, Sendable {
    case unknown
    case missing
    case installing(progress: Double)
    case ready(ytDlp: ToolLocation, ffmpeg: ToolLocation?)
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Finds, installs and updates the external tools.
@MainActor
public protocol ToolManaging: AnyObject {
    /// Current state, without touching the network.
    func resolve() async -> ToolStatus

    /// Downloads whatever is missing (yt-dlp, and ffmpeg when the system has
    /// none), verifying checksums, and reports progress through `progress`.
    func installMissing(progress: @escaping @MainActor (Double) -> Void) async throws -> ToolStatus

    /// Re-downloads the managed yt-dlp when a newer release exists.
    func updateYtDlp() async throws -> ToolStatus
}

/// The real implementation.
///
/// TODO(T1): implement.
/// - yt-dlp: `yt-dlp_macos.zip` (onedir build, starts much faster than the
///   onefile `yt-dlp_macos`) from
///   https://github.com/yt-dlp/yt-dlp/releases/latest/download/, verified
///   against `SHA2-256SUMS` from the same release, unpacked into
///   `<container>/tools/yt-dlp/`, `chmod +x`.
/// - ffmpeg: look in /opt/homebrew/bin, /usr/local/bin, then PATH; else
///   download a static build for the running architecture into
///   `<container>/tools/ffmpeg`.
/// - Honour the custom paths stored in preferences (`PreferenceKey`).
/// - Everything under the network is `network-client` + `downloads`; check
///   `host.isGranted` and surface a refusal as `.failed`.
@MainActor
public final class ToolManager: ToolManaging {
    private let containerDirectory: URL
    private let log: @MainActor (String) -> Void

    public init(containerDirectory: URL, log: @escaping @MainActor (String) -> Void) {
        self.containerDirectory = containerDirectory
        self.log = log
    }

    /// `<container>/tools`
    public var toolsDirectory: URL {
        containerDirectory.appendingPathComponent("tools", isDirectory: true)
    }

    public func resolve() async -> ToolStatus {
        log("ToolManager.resolve not implemented yet")
        return .missing
    }

    public func installMissing(progress: @escaping @MainActor (Double) -> Void) async throws -> ToolStatus {
        log("ToolManager.installMissing not implemented yet")
        return .failed("Not implemented")
    }

    public func updateYtDlp() async throws -> ToolStatus {
        log("ToolManager.updateYtDlp not implemented yet")
        return .failed("Not implemented")
    }
}
