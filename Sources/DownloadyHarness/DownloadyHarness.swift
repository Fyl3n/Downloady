//
//  DownloadyHarness.swift
//
//  Run with: droppykit run
//
//  Not named main.swift on purpose: Swift treats that name as top-level code,
//  which cannot coexist with @main.
//

import Downloady
import DroppyKit
import DroppyKitHarness
import Foundation

@main
struct DownloadyHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet {
        let droplet = DownloadyDroplet()
        // `DOWNLOADY_DEMO_QUEUE=1 droppykit run` fills the queue with jobs
        // that are not running, so the queue surface, the chip and the live
        // activity can be looked at without downloading anything. Harness
        // only: this target is never part of the bundle.
        if ProcessInfo.processInfo.environment["DOWNLOADY_DEMO_QUEUE"] == "1" {
            droplet.model.fillWithDemoJobs()
        }
        return droplet
    }
}
