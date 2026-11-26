import Foundation

enum ClipKind: String, Codable {
    case text
    case image
    case files
}

struct ClipItem: Codable, Identifiable, Equatable {
    let id: UUID
    var kind: ClipKind
    var text: String?
    var imageName: String?
    var filePaths: [String]?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var date: Date
    var pinned: Bool
    var sourceApp: String?
    var key: String

    var previewText: String {
        let raw = text ?? ""
        let collapsed = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(600))
    }

    var titleText: String {
        switch kind {
        case .text:
            return previewText
        case .image:
            return "图片"
        case .files:
            let paths = filePaths ?? []
            let names = paths.map { ($0 as NSString).lastPathComponent }
            if names.count > 2 {
                return names.prefix(2).joined(separator: "、") + " 等 \(names.count) 个文件"
            }
            return names.joined(separator: "、")
        }
    }

    var detailText: String {
        var parts: [String] = []
        switch kind {
        case .text:
            break
        case .image:
            if let w = pixelWidth, let h = pixelHeight {
                parts.append("\(w) × \(h)")
            }
        case .files:
            let count = filePaths?.count ?? 0
            parts.append("\(count) 个文件")
        }
        if let app = sourceApp, !app.isEmpty {
            parts.append(app)
        }
        parts.append(RelativeDate.string(from: date))
        return parts.joined(separator: "  ·  ")
    }

    var searchableText: String {
        var parts: [String] = []
        switch kind {
        case .text:
            parts.append(text ?? "")
        case .image:
            parts.append("图片 图像 截图 image screenshot")
        case .files:
            parts.append("文件 file folder")
            parts.append((filePaths ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: " "))
        }
        if let app = sourceApp {
            parts.append(app)
        }
        return parts.joined(separator: " ")
    }
}

enum RelativeDate {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    private static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    static func string(from date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 45 {
            return "刚刚"
        }
        if interval < 3600 {
            return "\(max(1, Int(interval / 60))) 分钟前"
        }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天 \(timeFormatter.string(from: date))"
        }
        if calendar.isDateInYesterday(date) {
            return "昨天 \(timeFormatter.string(from: date))"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return monthDayFormatter.string(from: date)
        }
        return fullFormatter.string(from: date)
    }
}
