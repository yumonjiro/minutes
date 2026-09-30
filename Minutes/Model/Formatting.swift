// 画面に出す文字の書式: 話者の頭文字・時刻・日時・長さ
import Foundation

/// アバターの 1 文字（「話者A」なら A、名前を付けたら頭文字）
func initial(of name: String) -> String {
    if let letter = name.wholeMatch(of: /話者([A-Z])/)?.1 { return String(letter) }
    return name.first.map(String.init) ?? "?"
}

/// 秒 → 「1:02:03」「2:05」
func formatTime(_ sec: Double) -> String {
    let s = max(0, Int(sec.isFinite ? sec : 0)), h = s / 3600, m = s / 60 % 60, x = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, x) : String(format: "%d:%02d", m, x)
}

/// 日時 → 「今日 14:05」「昨日 9:30」「9月26日」（年が違えば「2025年9月26日」）
func formatDate(_ date: Date) -> String {
    let cal = Calendar.current, time = date.formatted(date: .omitted, time: .shortened)
    if cal.isDateInToday(date) { return "今日 \(time)" }
    if cal.isDateInYesterday(date) { return "昨日 \(time)" }
    let c = cal.dateComponents([.year, .month, .day], from: date)
    let md = "\(c.month!)月\(c.day!)日"
    return cal.component(.year, from: .now) == c.year ? md : "\(c.year!)年" + md
}

/// 秒 → 「1時間5分」「12分」「45秒」
func formatDuration(_ sec: Double) -> String {
    let s = Int(sec.rounded())
    if s < 60 { return "\(s)秒" }
    let h = s / 3600, m = Int((Double(s % 3600) / 60).rounded())
    return h > 0 ? "\(h)時間" + (m > 0 ? "\(m)分" : "") : "\(m)分"
}
