import Combine
import Foundation

/// 錄完的影片在背景聽一次，看有沒有漏講、講錯數字。一次只聽一支，不擋任何操作。
/// 同時跑兩個辨識會互相打斷，所以錄影（語音跟隨）、對字幕的時候先讓開，之後再從頭聽。
/// 全部在主執行緒呼叫。
final class TakeChecker: ObservableObject {
    /// 先不要聽的原因。
    enum Hold: Hashable {
        case recording
        case captions
        case subtitles
        case background
    }

    /// 要檢查的一支影片。
    struct Job: Equatable {
        let url: URL
        let script: String
        /// 字幕一行幾個字。
        let maxChars: Int
        /// 之前聽過的。
        let hearing: TakeHearing?

        var file: String { url.lastPathComponent }
    }

    private enum Answer {
        case heard(TakeHearing, TakeReport)
        case failed(String)
    }

    /// 照檔名記。
    @Published private(set) var checks: [String: TakeCheck] = [:]
    /// 正在聽，而且要把聲音送出去。沒有在聽就是 false。
    @Published private(set) var sendsAudioOut = false
    /// 聽完一支。
    var onHeard: ((String, TakeHearing) -> Void)?
    var onLog: ((String) -> Void)?

    private var jobs: [Job] = []
    private var holds: Set<Hold> = []
    private var runningFile: String?
    private var task: Task<Void, Never>?
    /// 取消過的那一次晚回來不算。
    private var ticket = 0
    /// 沒檢查到的最多再試幾次，不要每次回到前景都重聽。
    private static let mostRetries = 3

    /// 稿子裡有會唸出來的字才有東西可以比。
    static func canCheck(_ script: String) -> Bool {
        script.contains { SpokenKeys.key(for: $0) != nil }
    }

    /// 現在該檢查的有哪些，排前面的先做。不在裡面的（重錄、刪段、換稿）馬上取消，結果也丟掉。
    func sync(_ wanted: [Job]) {
        guard wanted != jobs else { return }
        jobs = wanted
        var next: [String: TakeCheck] = [:]
        for job in wanted {
            guard var known = checks[job.file], known.script == job.script else {
                next[job.file] = TakeCheck(script: job.script, maxChars: job.maxChars)
                continue
            }
            // 上次沒聽全，後來對字幕時聽全了，拿那份再比一次。
            let hadAll: Bool = known.hearing?.isComplete ?? false
            let hasAll: Bool = job.hearing?.isComplete ?? false
            if known.isFinished, hasAll, !hadAll { known.state = TakeCheck.State.waiting }
            if known.maxChars != job.maxChars {
                known.maxChars = job.maxChars
                // 聽過的拿來重比就好。沒聽全的不為了這個再聽一次。
                if hasAll || !known.isFinished { known.state = TakeCheck.State.waiting }
            }
            next[job.file] = known
        }
        if next != checks { checks = next }
        if let runningFile, next[runningFile]?.state != TakeCheck.State.checking { stopRunning() }
        pump()
    }

    /// 讓開，或可以繼續了。
    func hold(_ reason: Hold, _ on: Bool) {
        if on {
            guard holds.insert(reason).inserted else { return }
            stopRunning()
        } else {
            guard holds.remove(reason) != nil else { return }
            if reason == Hold.background { retryFailed() }
            pump()
        }
    }

    /// 沒檢查到的回到前景再試，多半是當時沒有網路。
    private func retryFailed() {
        for job in jobs {
            guard var check = checks[job.file], check.isFinished, check.retries < Self.mostRetries,
                  !(check.hearing?.isComplete ?? false) else { continue }
            check.retries += 1
            check.earlier = check.report
            check.state = TakeCheck.State.waiting
            checks[job.file] = check
        }
    }

    private func stopRunning() {
        guard let file = runningFile else { return }
        ticket += 1
        task?.cancel()
        task = nil
        runningFile = nil
        if checks[file]?.state == TakeCheck.State.checking {
            checks[file]?.state = TakeCheck.State.waiting
        }
        if sendsAudioOut { sendsAudioOut = false }
    }

    private func pump() {
        guard runningFile == nil else { return }
        guard holds.isEmpty,
              let job = jobs.first(where: { checks[$0.file]?.state == TakeCheck.State.waiting }) else {
            if sendsAudioOut { sendsAudioOut = false }
            return
        }
        ticket += 1
        let mine = ticket
        runningFile = job.file
        checks[job.file]?.state = TakeCheck.State.checking
        let isKnown: Bool = job.hearing?.isComplete ?? false
        let sends: Bool = isKnown ? false : CaptionBridge.sendsAudioOut
        if sends != sendsAudioOut { sendsAudioOut = sends }
        let began = Date()
        task = Task(priority: .utility) {
            let answer = await TakeChecker.answer(job)
            await MainActor.run {
                self.finished(job, answer, began: began, ticket: mine)
            }
        }
    }

    private static func answer(_ job: Job) async -> Answer {
        do {
            let hearing: TakeHearing
            if let known = job.hearing, known.isComplete {
                hearing = known
            } else {
                hearing = try await CaptionBuilder.hear(job.url, script: job.script)
            }
            try Task.checkCancellation()
            let report: TakeReport = Self.report(job, hearing)
            try Task.checkCancellation()
            return .heard(hearing, report)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 對稿子很長的時候要算一陣子。被錄影打斷（取消）就中途放棄，這一份結果不用。
    /// 刻意不是 async：在 async 裡 withValue 會挑到 async 的那個版本。
    private static func report(_ job: Job, _ hearing: TakeHearing) -> TakeReport {
        CaptionAligner.$stopsWhenCancelled.withValue(true) {
            TakeReport(script: job.script, hearing: hearing, maxChars: job.maxChars)
        }
    }

    private func finished(_ job: Job, _ answer: Answer, began: Date, ticket mine: Int) {
        guard mine == ticket, runningFile == job.file else { return }
        runningFile = nil
        task = nil
        let seconds: Double = Date().timeIntervalSince(began)
        switch answer {
        case .heard(let hearing, let report):
            onLog?(Self.summary(hearing, report, seconds: seconds))
            let earlier: TakeReport? = checks[job.file]?.earlier
            checks[job.file]?.earlier = nil
            if let earlier, report.isIncomplete, report.issues.count < earlier.issues.count {
                // 再聽還是沒聽全，找到的又比較少，留著上次的。
                checks[job.file]?.state = TakeCheck.State.done(earlier)
            } else {
                checks[job.file]?.state = TakeCheck.State.done(report)
                // 幾乎沒聽到的不留也不存，加字幕、下次打開都重新聽。
                checks[job.file]?.hearing = report.heardLittle ? nil : hearing
                // 外面會存起來，接著再叫 sync。
                if hearing != job.hearing, !report.heardLittle { onHeard?(job.file, hearing) }
            }
        case .failed(let reason):
            checks[job.file]?.state = TakeCheck.State.failed
            onLog?(String(format: "這段檢查沒成功，花 %.1f 秒：", seconds) + reason)
        }
        pump()
    }

    /// 除錯紀錄只記數量和時間，不記內容。
    private static func summary(_ hearing: TakeHearing, _ report: TakeReport, seconds: Double) -> String {
        var text = "這段檢查：數字 \(report.count(.number))、漏講 \(report.count(.missing))、一字之差 \(report.count(.word))"
        text += "、沒聽清楚 \(report.unclear)"
        if report.isIncomplete { text += "、沒檢查全" }
        text += String(format: "，%@，影片 %.1f 秒，花 %.1f 秒", hearing.engine, hearing.to - hearing.from, seconds)
        return text
    }
}
