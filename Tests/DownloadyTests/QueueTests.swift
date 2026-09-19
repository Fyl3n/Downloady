//
//  QueueTests.swift
//  DownloadyTests
//
//  The queue's rules: which job each lane takes next, and what the notch
//  shows while they run.
//

import Foundation
import Testing

@testable import Downloady

@Suite struct QueueLaneTests {
    private func job(_ state: DownloadJob.State, title: String = "A") -> DownloadJob {
        DownloadJob(
            url: URL(string: "https://youtu.be/\(title)")!,
            title: title,
            options: DownloadOptions(),
            state: state
        )
    }

    @Test func theDownloadLaneTakesOneJobAtATime() {
        #expect([job(.waiting), job(.waiting)].nextToDownload?.title == "A")
        let running = [job(.downloading(fraction: 0.2, speed: nil, eta: nil)), job(.waiting, title: "B")]
        #expect(running.nextToDownload == nil)
        #expect([job(.postProcessing), job(.waiting, title: "B")].nextToDownload == nil)
    }

    /// A transcript runs beside the next download, not behind it.
    @Test func theTranscriptLaneRunsWhileADownloadDoes() {
        let jobs = [job(.waitingForTranscript), job(.downloading(fraction: 0.5, speed: nil, eta: nil), title: "B")]
        #expect(jobs.nextToTranscribe?.title == "A")
        #expect(jobs.nextToDownload == nil)
    }

    @Test func theTranscriptLaneAlsoTakesOneAtATime() {
        let jobs = [job(.transcribing(fraction: 0.1)), job(.waitingForTranscript, title: "B")]
        #expect(jobs.nextToTranscribe == nil)
    }

    @Test func finishedJobsAreNotActive() {
        #expect(!job(.finished).isActive)
        #expect(!job(.failed("nope")).isActive)
        #expect(job(.waitingForTranscript).isActive)
        #expect(job(.waitingForTranscript).isTranscribing)
        #expect(job(.postProcessing).isDownloading)
    }
}

@Suite struct QueueSummaryTests {
    private func job(_ state: DownloadJob.State, title: String = "A") -> DownloadJob {
        DownloadJob(
            url: URL(string: "https://youtu.be/\(title)")!,
            title: title,
            options: DownloadOptions(),
            state: state
        )
    }

    @Test func aQuietQueueAsksForNothing() {
        #expect(!QueueSummary(jobs: []).isActive)
        #expect(!QueueSummary(jobs: [job(.finished)]).isActive)
        #expect(QueueSummary(jobs: [job(.finished)]).activityLabel.isEmpty)
    }

    /// The running download owns the notch; a transcript only gets it when
    /// nothing is downloading.
    @Test func theDownloadLeadsTheNotch() {
        let jobs = [job(.transcribing(fraction: 0.4)), job(.downloading(fraction: 0.25, speed: nil, eta: nil), title: "B")]
        let summary = QueueSummary(jobs: jobs)
        #expect(summary.leading?.title == "B")
        #expect(summary.fraction == 0.25)
        // The percentage is written the way this Mac writes percentages.
        #expect(summary.activityLabel == "\(0.25.formatted(.percent.precision(.fractionLength(0)))) · 2")
    }

    @Test func aLoneTranscriptLeads() {
        let summary = QueueSummary(jobs: [job(.transcribing(fraction: 0.6))])
        #expect(summary.leading?.isTranscribing == true)
        #expect(summary.activityLabel == 0.6.formatted(.percent.precision(.fractionLength(0))))
    }

    @Test func stagesWithNoNumberGetAWord() {
        #expect(QueueSummary(jobs: [job(.postProcessing)]).activityLabel == "Finishing")
        #expect(QueueSummary(jobs: [job(.preparingTranscript)]).activityLabel == "Text")
        #expect(QueueSummary(jobs: [job(.waiting)]).activityLabel == "Queued")
    }
}

@MainActor
@Suite struct QueueModelTests {
    @Test func theFormFollowsTheJobStartedFromItsLink() {
        let model = DownloadModel()
        #expect(model.currentJob == nil)
        #expect(model.backgroundJobs.isEmpty)
    }

    @Test func aTranscriptLandsBesideTheMediaItWasMadeFrom() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("downloady-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let media = folder.appendingPathComponent("Clip [abc].mp4")
        try Data().write(to: media)
        #expect(DownloadModel.subtitleFile(beside: media) == nil)

        let subtitles = folder.appendingPathComponent("Clip [abc].en.srt")
        try Data().write(to: subtitles)
        // Another video's subtitles in the same folder are not this one's.
        try Data().write(to: folder.appendingPathComponent("Other [xyz].en.srt"))
        #expect(DownloadModel.subtitleFile(beside: media) == subtitles)
    }
}

@Suite struct ProgressThrottleTests {
    private func downloading(_ fraction: Double, speed: String? = "1MiB/s") -> DownloadJob.State {
        .downloading(fraction: fraction, speed: speed, eta: "00:10")
    }

    @Test func aTickInsideTheSamePercentWaits() {
        #expect(!DownloadJob.shouldPublish(downloading(0.421), over: downloading(0.420), elapsed: 0.5))
    }

    @Test func aNewPercentPublishesOnceTheIntervalPassed() {
        #expect(!DownloadJob.shouldPublish(downloading(0.43), over: downloading(0.42), elapsed: 0.05))
        #expect(DownloadJob.shouldPublish(downloading(0.43), over: downloading(0.42), elapsed: 0.3))
    }

    @Test func theSpeedRefreshesEverySecond() {
        #expect(DownloadJob.shouldPublish(downloading(0.42, speed: "2MiB/s"), over: downloading(0.42), elapsed: 1.2))
    }

    @Test func aNewStageAlwaysPublishes() {
        #expect(DownloadJob.shouldPublish(.postProcessing, over: downloading(0.99), elapsed: 0))
        #expect(DownloadJob.shouldPublish(.transcribing(fraction: 0.01), over: .preparingTranscript, elapsed: 0))
    }
}
