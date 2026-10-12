//  PaperLogTests.swift — reading hours off a photo of a paper driving log.

import XCTest
@testable import DrivebyCore

final class PaperLogTests: XCTestCase {

    // MARK: Written totals win

    func testWrittenTotalIsUsed() {
        let e = PaperLog.estimate(lines: [
            "Date  Hours  Day/Night  Initials",
            "9/14  1.5  Day  JK",
            "9/16  2  Night  JK",
            "Total hours: 23.5",
        ])
        XCTAssertTrue(e.fromWrittenTotal)
        XCTAssertEqual(e.totalMinutes, 23.5 * 60, accuracy: 0.1)
    }

    func testNightTotalIsReadSeparately() {
        let e = PaperLog.estimate(lines: ["Total: 20 hrs", "Night total: 6 hrs 30 min"])
        XCTAssertEqual(e.totalMinutes, 20 * 60, accuracy: 0.1)
        XCTAssertEqual(e.nightMinutes, 6.5 * 60, accuracy: 0.1)
    }

    func testRunningTotalTakesTheLargest() {
        let e = PaperLog.estimate(lines: ["Page total 4:30", "Running total 18:45"])
        XCTAssertEqual(e.totalMinutes, 18.75 * 60, accuracy: 0.1)
    }

    func testRequirementTextIsNotATotal() {
        let e = PaperLog.estimate(lines: [
            "You must complete 45 hours of supervised driving, 15 hours after sunset.",
            "Total hours required: 45",
            "10/1  1 hr",
        ])
        XCTAssertFalse(e.fromWrittenTotal)
        XCTAssertEqual(e.totalMinutes, 60, accuracy: 0.1)
    }

    // MARK: Adding up sessions

    func testSessionsWithUnitsAreSummed() {
        let e = PaperLog.estimate(lines: ["10/1  1 hr 15 min", "10/3  45 minutes", "10/4  2h"])
        XCTAssertFalse(e.fromWrittenTotal)
        XCTAssertEqual(e.sessions.count, 3)
        XCTAssertEqual(e.totalMinutes, 75 + 45 + 120, accuracy: 0.1)
    }

    func testTimeRangesBecomeDurations() {
        let e = PaperLog.estimate(lines: ["10/1  4:15 - 5:30 pm", "10/2  11:30am to 1:00pm", "10/3  7:45-8:15"])
        XCTAssertEqual(e.sessions.map(\.minutes), [75, 90, 30])
    }

    func testRangeIsNotMistakenForADate() {
        // "15-5" inside "4:15-5:30" must not be read as a date and swallowed.
        XCTAssertEqual(PaperLog.durationMinutes(in: "4:15-5:30"), 75)
    }

    func testNightSessionsAreCounted() {
        let e = PaperLog.estimate(lines: ["10/1  1:30  Night", "10/2  1:00  Day", "10/3  0:45  N"])
        XCTAssertEqual(e.totalMinutes, 90 + 60 + 45, accuracy: 0.1)
        XCTAssertEqual(e.nightMinutes, 90 + 45, accuracy: 0.1)
    }

    func testBareNumbersNeedADateOnTheLine() {
        let e = PaperLog.estimate(lines: ["10/12/2025  1.5  D", "Page 2", "Instructor 3"])
        XCTAssertEqual(e.sessions.count, 1)
        XCTAssertEqual(e.totalMinutes, 90, accuracy: 0.1)
    }

    func testBareMinutesWithDate() {
        XCTAssertEqual(PaperLog.estimate(lines: ["10/12  45  Day"]).totalMinutes, 45, accuracy: 0.1)
    }

    func testImplausibleSessionsAreDropped() {
        let e = PaperLog.estimate(lines: ["10/1  30 hours", "10/2  1 hr"])
        XCTAssertEqual(e.totalMinutes, 60, accuracy: 0.1)
    }

    func testStartTimeAndDurationColumnsPickTheDuration() {
        // "3:45" (start time, no am/pm) and "1:30" (duration) on one row → the smaller is the duration.
        XCTAssertEqual(PaperLog.durationMinutes(in: "10/1  3:45  1:30  JK"), 90)
    }

    func testEmptyPhoto() {
        let e = PaperLog.estimate(lines: ["Driving Log", "Name ____", "Signature"])
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(e.nightMinutes, 0)
    }

    func testNightNeverExceedsTotal() {
        let e = PaperLog.estimate(lines: ["Total 5 hrs", "Night total 8 hrs"])
        XCTAssertLessThanOrEqual(e.nightMinutes, e.totalMinutes)
    }

    // MARK: Review fixes — totals, targets, start times

    func testTotalAndNightTotalOnOneLine() {
        let e = PaperLog.estimate(lines: ["Total hours: 45  Night hours: 15"])
        XCTAssertTrue(e.fromWrittenTotal)
        XCTAssertEqual(e.totalMinutes, 45 * 60, accuracy: 0.1)
        XCTAssertEqual(e.nightMinutes, 15 * 60, accuracy: 0.1)
    }

    func testRequirementSentenceWithIncludingIsIgnored() {
        let e = PaperLog.estimate(lines: ["Virginia: 45 hours total including 15 at night", "10/1  1 hr", "10/2  2 hrs"])
        XCTAssertFalse(e.fromWrittenTotal)
        XCTAssertEqual(e.totalMinutes, 180, accuracy: 0.1)
        XCTAssertEqual(e.nightMinutes, 0, accuracy: 0.1)
    }

    func testPrintedTargetIsNotTheTotal() {
        XCTAssertEqual(PaperLog.estimate(lines: ["Total: 12.5 / 45"]).totalMinutes, 12.5 * 60, accuracy: 0.1)
        XCTAssertEqual(PaperLog.estimate(lines: ["Total hours 12.5 of 45"]).totalMinutes, 12.5 * 60, accuracy: 0.1)
        XCTAssertTrue(PaperLog.estimate(lines: ["Total ___ / 45"]).isEmpty)
        XCTAssertEqual(PaperLog.estimate(lines: ["Total of 23 hours"]).totalMinutes, 23 * 60, accuracy: 0.1)
    }

    func testLoneStartTimeIsNotADuration() {
        XCTAssertNil(PaperLog.durationMinutes(in: "10/1  4:15"))
    }

    func testStartAndEndColumnsBecomeARange() {
        XCTAssertEqual(PaperLog.durationMinutes(in: "10/1  4:15  5:30"), 75)
    }

    func testDottedTimesFromOCRAreARange() {
        XCTAssertEqual(PaperLog.durationMinutes(in: "10/1  4.15-5.30 pm"), 75)
    }

    // MARK: OCR rows

    func testFragmentsAreGroupedIntoRows() {
        // y grows downward; two table rows, cells recognised out of order.
        let rows = PaperLog.rows([
            OCRFragment(text: "1:30", minX: 0.4, midY: 0.205, height: 0.02),
            OCRFragment(text: "10/1", minX: 0.1, midY: 0.200, height: 0.02),
            OCRFragment(text: "Night", minX: 0.6, midY: 0.198, height: 0.02),
            OCRFragment(text: "10/2", minX: 0.1, midY: 0.250, height: 0.02),
            OCRFragment(text: "1:00", minX: 0.4, midY: 0.252, height: 0.02),
        ])
        XCTAssertEqual(rows, ["10/1  1:30  Night", "10/2  1:00"])
    }
}
