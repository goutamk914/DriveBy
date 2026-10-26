import UIKit

enum PracticeLogPDF {
    static func render(entries: [PracticeLogEntry], summary: HoursSummary, learner: String) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 48
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: {
            let f = UIGraphicsPDFRendererFormat()
            f.documentInfo = [kCGPDFContextTitle as String: "Driveby supervised driving log",
                              kCGPDFContextCreator as String: "Driveby"]
            return f
        }())

        let title: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 20, weight: .bold)]
        let h2: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12, weight: .semibold)]
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10)]
        let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8.5), .foregroundColor: UIColor.darkGray]
        let mono: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)]

        let dateF = DateFormatter(); dateF.dateStyle = .medium; dateF.timeStyle = .none
        let timeF = DateFormatter(); timeF.dateStyle = .none; timeF.timeStyle = .short
        let sorted = entries.sorted { $0.startedAt < $1.startedAt }

        let cols: [(String, CGFloat)] = [("#", 24), ("Date", 92), ("Start", 60), ("Duration", 64), ("Night", 56),
                                         ("Supervisor", 140), ("Source", 80)]

        return renderer.pdfData { ctx in
            var y: CGFloat = 0
            var pageNo = 0

            func newPage() {
                ctx.beginPage()
                pageNo += 1
                y = margin
                ("Driveby: supervised driving log" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: title)
                y += 28
                let who = learner.trimmingCharacters(in: .whitespaces).isEmpty ? "______________________________" : learner
                ("Learner: \(who)    Requirement: \(fmt(summary.requirement.totalHours)) h total, \(fmt(summary.requirement.nightHours)) h after sunset (\(summary.requirement.label))" as NSString)
                    .draw(at: CGPoint(x: margin, y: y), withAttributes: body)
                y += 16
                ("Page \(pageNo) · generated \(dateF.string(from: Date()))" as NSString)
                    .draw(at: CGPoint(x: margin, y: y), withAttributes: small)
                y += 20
                var x = margin
                for (name, w) in cols {
                    (name as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: h2)
                    x += w
                }
                y += 16
                ctx.cgContext.setStrokeColor(UIColor.gray.cgColor)
                ctx.cgContext.stroke(CGRect(x: margin, y: y, width: page.width - 2 * margin, height: 0.5))
                y += 6
            }

            newPage()
            for (i, e) in sorted.enumerated() {
                if y > page.height - margin - 150 { newPage() }
                let cells = ["\(i + 1)", dateF.string(from: e.startedAt), timeF.string(from: e.startedAt),
                             HoursSummary.hoursString(e.durationS), HoursSummary.hoursString(e.nightS),
                             e.supervisor.isEmpty ? "-" : e.supervisor, e.manual ? "Added by hand" : "Recorded"]
                var x = margin
                for (n, (text, w)) in zip(cells, cols.map(\.1)).enumerated() {
                    let r = CGRect(x: x, y: y, width: w - 6, height: 14)
                    (text as NSString).draw(with: r, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                                            attributes: (n == 3 || n == 4) ? mono : body, context: nil)
                    x += w
                }
                y += 16
            }
            if sorted.isEmpty {
                ("No sessions logged yet." as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: body)
                y += 16
            }

            if y > page.height - margin - 150 { newPage() }
            y += 10
            ctx.cgContext.stroke(CGRect(x: margin, y: y, width: page.width - 2 * margin, height: 0.5))
            y += 10
            ("Total: \(HoursSummary.hoursString(summary.totalS))    After sunset: \(HoursSummary.hoursString(summary.nightS))    Sessions: \(sorted.count)" as NSString)
                .draw(at: CGPoint(x: margin, y: y), withAttributes: h2)
            y += 40
            let line = (page.width - 2 * margin - 24) / 2
            for (i, label) in ["Parent / guardian signature", "Date"].enumerated() {
                let x = margin + CGFloat(i) * (line + 24)
                ctx.cgContext.stroke(CGRect(x: x, y: y, width: line, height: 0.5))
                (label as NSString).draw(at: CGPoint(x: x, y: y + 4), withAttributes: small)
            }
            y += 30
            let note = "Personal record, not the official state log. Night time is estimated from sunset. "
                + Disclaimer.full
            (note as NSString).draw(with: CGRect(x: margin, y: y, width: page.width - 2 * margin, height: 80),
                                    options: [.usesLineFragmentOrigin], attributes: small, context: nil)
        }
    }

    private static func fmt(_ h: Double) -> String {
        h.rounded() == h ? String(format: "%.0f", h) : String(format: "%.1f", h)
    }
}
