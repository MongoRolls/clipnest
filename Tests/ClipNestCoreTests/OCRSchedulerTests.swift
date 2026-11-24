import XCTest
@testable import ClipNestCore

final class OCRSchedulerTests: XCTestCase {
    func testManualJoiningBackgroundSurvivesDisable() throws {
        var scheduler = OCRScheduler()
        let begin = scheduler.receive(.candidates(["first", "second"]))
        guard case .start(let job) = begin.first else { return XCTFail("未开始后台识别") }
        XCTAssertFalse(job.manual)
        XCTAssertEqual(scheduler.receive(.manual(job.id)), [])
        XCTAssertEqual(scheduler.receive(.manual(job.id)), [])
        XCTAssertEqual(scheduler.receive(.automatic(false)), [])
        XCTAssertEqual(scheduler.receive(.finished(job, failed: false)), [.deliver(job.id)])
    }

    func testNextJobCanBeCancelledByPreviousCallback() throws {
        var scheduler = OCRScheduler()
        guard case .start(let first) = scheduler.receive(.manual("manual")).first else { return XCTFail("缺少手动任务") }
        XCTAssertEqual(scheduler.receive(.candidates(["background"])), [])
        let actions = scheduler.receive(.finished(first, failed: false))
        guard case .start(let next) = actions.first else { return XCTFail("调用用户回调前应安装下一个任务") }
        XCTAssertEqual(actions, [.start(next), .deliver(first.id)])
        XCTAssertEqual(next.id, "background")
        XCTAssertEqual(scheduler.receive(.automatic(false)), [.cancelActive])
        XCTAssertEqual(scheduler.receive(.finished(next, failed: true)), [])
    }

    func testPreemptionFailureRetryAndStop() throws {
        var scheduler = OCRScheduler()
        guard case .start(let background) = scheduler.receive(.candidates(["background"])).first else { return XCTFail("缺少后台任务") }
        XCTAssertEqual(scheduler.receive(.manual("manual")), [.cancelActive])
        guard case .start(let manual) = scheduler.receive(.finished(background, failed: true)).first else { return XCTFail("缺少下一次手动任务") }
        XCTAssertTrue(manual.manual)
        guard case .start(let retry) = scheduler.receive(.finished(manual, failed: false)).first else { return XCTFail("被打断的后台图片应继续识别") }
        XCTAssertEqual(retry.id, background.id)
        XCTAssertEqual(scheduler.receive(.finished(retry, failed: true)), [.deliver(retry.id)])
        XCTAssertEqual(scheduler.receive(.candidates([retry.id])), [])
        guard case .start(let explicit) = scheduler.receive(.manual(retry.id)).first else { return XCTFail("手动可以重试") }
        XCTAssertEqual(scheduler.receive(.stop), [.cancelActive, .cancelWaiting])
        XCTAssertEqual(scheduler.receive(.finished(explicit, failed: false)), [])
        XCTAssertEqual(scheduler.receive(.wake), [])
        XCTAssertEqual(scheduler.receive(.candidates(["later"])), [])
    }

    func testWakeRetriesOnlyUnfinishedWork() {
        var scheduler = OCRScheduler()
        guard case .start(let first) = scheduler.receive(.candidates(["image"])).first else { return XCTFail("缺少初始任务") }
        XCTAssertEqual(scheduler.receive(.sleep), [.cancelActive, .cancelWaiting])
        XCTAssertEqual(scheduler.receive(.finished(first, failed: true)), [])
        XCTAssertEqual(scheduler.receive(.candidates(["image"])), [])
        guard case .start(let resumed) = scheduler.receive(.wake).first else { return XCTFail("唤醒后应恢复索引") }
        XCTAssertEqual(resumed.id, first.id)
        XCTAssertNotEqual(resumed, first)
        XCTAssertEqual(scheduler.receive(.finished(first, failed: true)), [])
        XCTAssertEqual(scheduler.receive(.finished(resumed, failed: false)), [.deliver(resumed.id)])
    }
}
