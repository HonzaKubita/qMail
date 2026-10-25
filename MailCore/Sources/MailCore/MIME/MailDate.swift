import Foundation

/// Date parsing for mail headers. Hand-rolled because real-world `Date:` headers are far
/// too inconsistent for a fixed `DateFormatter` pattern.
public enum MailDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private static let zones: [String: Int] = [
        "UT": 0, "UTC": 0, "GMT": 0, "Z": 0,
        "EST": -5, "EDT": -4, "CST": -6, "CDT": -5, "MST": -7, "MDT": -6, "PST": -8, "PDT": -7,
        "CET": 1, "CEST": 2, "BST": 1, "IST": 5, "JST": 9,
    ]

    /// Parses RFC 5322 dates like `Tue, 15 Nov 1994 08:12:31 -0800 (PST)` and common variants.
    public static func parseRFC5322(_ input: String) -> Date? {
        var text = input
        // Drop comments such as "(PST)".
        while let open = text.firstIndex(of: "("), let close = text[open...].firstIndex(of: ")") {
            text.removeSubrange(open...close)
        }
        let tokens = text
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)

        var day: Int?, month: Int?, year: Int?
        var hour = 0, minute = 0, second = 0
        var offset = 0
        var sawTime = false

        for token in tokens {
            let lower = token.lowercased()
            if token.contains(":"), !sawTime {
                let parts = token.split(separator: ":").compactMap { Int($0) }
                if parts.count >= 2 {
                    hour = parts[0]
                    minute = parts[1]
                    second = parts.count > 2 ? parts[2] : 0
                    sawTime = true
                }
            } else if let index = months.firstIndex(where: { lower.hasPrefix($0) }), month == nil, token.count >= 3,
                      Int(token) == nil {
                month = index + 1
            } else if (token.hasPrefix("+") || token.hasPrefix("-")), token.count == 5, let value = Int(token.dropFirst()) {
                let sign = token.hasPrefix("-") ? -1 : 1
                offset = sign * ((value / 100) * 3600 + (value % 100) * 60)
            } else if let hours = zones[token.uppercased()] {
                offset = hours * 3600
            } else if let number = Int(token) {
                if day == nil, number >= 1, number <= 31, token.count <= 2, month == nil || year == nil {
                    day = number
                } else if year == nil {
                    year = number
                } else if day == nil {
                    day = number
                }
            }
        }

        guard let day, let month, var year else { return nil }
        if year < 50 {
            year += 2000
        } else if year < 1000 {
            year += 1900
        }
        return makeDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second, offset: offset)
    }

    /// Parses IMAP INTERNALDATE, e.g. `17-Jul-1996 02:44:25 -0700`.
    public static func parseInternalDate(_ input: String) -> Date? {
        let parts = input.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let dateParts = parts[0].split(separator: "-")
        let timeParts = parts[1].split(separator: ":").compactMap { Int($0) }
        guard dateParts.count == 3, timeParts.count == 3,
              let day = Int(dateParts[0]), let year = Int(dateParts[2]),
              let monthIndex = months.firstIndex(of: dateParts[1].lowercased()) else { return nil }
        var offset = 0
        if parts.count > 2, let value = Int(parts[2].dropFirst()) {
            let sign = parts[2].hasPrefix("-") ? -1 : 1
            offset = sign * ((value / 100) * 3600 + (value % 100) * 60)
        }
        return makeDate(year: year, month: monthIndex + 1, day: day,
                        hour: timeParts[0], minute: timeParts[1], second: timeParts[2], offset: offset)
    }

    /// Formats a date for a `Date:` header in the local time zone.
    public static func formatRFC5322(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    static func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, offset: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour),
              (0...59).contains(minute), (0...60).contains(second) else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Howard Hinnant's days_from_civil algorithm.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
