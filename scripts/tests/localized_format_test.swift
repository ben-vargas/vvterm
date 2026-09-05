import Foundation

// Compile this file with VVTermShared/LocalizedFormat.swift. The temporary bundles
// deliberately use a different language from the process's preferred language.
@main
struct LocalizedFormatTest {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let cases: [String: [(Int64, String)]] = [
            "en": [(0, "0 active sessions"), (1, "1 active session"), (2, "2 active sessions")],
            "zh-Hans": [(1, "1 个活动会话"), (21, "21 个活动会话")],
            "ja": [(2, "アクティブなセッション 2件")],
            "ko": [(2, "활성 세션 2개")],
            "th": [(2, "2 เซสชันที่ใช้งานอยู่")],
            "vi": [(2, "2 phiên đang hoạt động")],
            "es": [(1, "1 sesión activa"), (2, "2 sesiones activas")],
            "fr": [(1, "1 session active"), (2, "2 sessions actives")],
            "de": [(1, "1 aktive Sitzung"), (2, "2 aktive Sitzungen")],
            "ru": [(1, "1 активный сеанс"), (2, "2 активных сеанса"), (5, "5 активных сеансов"), (11, "11 активных сеансов"), (21, "21 активный сеанс"), (22, "22 активных сеанса")],
            "be": [(1, "1 актыўны сеанс"), (2, "2 актыўныя сеансы"), (5, "5 актыўных сеансаў"), (21, "21 актыўны сеанс")],
            "uk": [(1, "1 активний сеанс"), (2, "2 активні сеанси"), (5, "5 активних сеансів"), (21, "21 активний сеанс")],
            "pl": [(1, "1 aktywna sesja"), (2, "2 aktywne sesje"), (5, "5 aktywnych sesji"), (12, "12 aktywnych sesji"), (21, "21 aktywnych sesji"), (22, "22 aktywne sesje")],
            "cs": [(1, "1 aktivní relace"), (2, "2 aktivní relace"), (5, "5 aktivních relací"), (21, "21 aktivních relací")]
        ]
        var checks = 0
        for owner in ["VVTerm", "VVTermLiveActivity"] {
            for (language, samples) in cases {
                let path = temporary.appendingPathComponent("\(owner)-\(language).bundle")
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                let info: [String: Any] = ["CFBundleIdentifier": "test.\(owner).\(language)", "CFBundleDevelopmentRegion": language]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: path.appendingPathComponent("Info.plist"))
                try FileManager.default.copyItem(at: root.appendingPathComponent("\(owner)/Resources/\(language).lproj"), to: path.appendingPathComponent("\(language).lproj"))
                let bundle = Bundle(url: path)!
                let dictionary = try PropertyListSerialization.propertyList(from: Data(contentsOf: path.appendingPathComponent("\(language).lproj/Localizable.stringsdict")), format: nil) as! [String: Any]
                for key in dictionary.keys {
                    for count: Int64 in [0, 1, 2, 5, 11, 21, 22, 101] {
                        let actual = LocalizedFormat.string(key, count, bundle: bundle)
                        precondition(!actual.contains("%") && actual.contains(String(count)), "Unresolved plural: \(language)/\(key): \(actual)")
                        checks += 1
                    }
                }
                for (count, expected) in samples {
                    let actual = LocalizedFormat.string("%lld active sessions", count, bundle: bundle)
                    precondition(actual == expected, "\(owner)/\(language): expected \(expected), got \(actual)")
                    checks += 1
                }
                if owner == "VVTerm", language == "zh-Hans" {
                    for (key, expected) in ["CPU": "CPU", "Markdown Document": "Markdown 文档", "Swift Source": "Swift 源代码", "Bar": "竖线", "Key": "按键", "Key Actions": "密钥操作", "Parent": "上级文件夹", "Keyboard Home": "Home"] {
                        precondition(LocalizedFormat.string(key, bundle: bundle) == expected, "Incorrect Chinese term: \(key)")
                        checks += 1
                    }
                }
            }
        }
        print("PASS: \(checks) app and widget format and terminology checks across all 14 languages.")
    }
}
