import Foundation

enum CodexHarnessConfigError: Error, LocalizedError {
    case invalidUTF8
    case unsupportedSyntax(String)
    case conflict(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Codex 配置文件不是有效的 UTF-8。"
        case .unsupportedSyntax(let reason):
            return "Codex 配置包含暂时无法安全处理的 TOML：\(reason)"
        case .conflict(let reason):
            return "Codex 配置存在冲突，已停止修改：\(reason)"
        }
    }
}

/// 把 Codex 的 config.toml 文本转换成 EZ Switch 使用的纯 TOML。
///
/// Foundation 没有 TOML 解析器。这里只实现 Codex 配置文件实际使用的窄语法，
/// 并在无法确认结构安全时拒绝修改，而不是尝试猜测或重写整个文件。
enum CodexHarnessConfig {
    static func configure(_ original: Data?, endpoint: String, modelID: String) throws -> Data {
        let modelValue = try tomlString(modelID)
        let endpointValue = try tomlString(endpoint)

        let originalLines = try decodeLines(original)
        let document = try TOMLDocument.parse(originalLines)
        let withTopLevel = document.replacingTopLevel(
            modelValue: modelValue,
            providerValue: try tomlString("ezswitch")
        )

        let reparsed = try TOMLDocument.parse(withTopLevel.lines)
        let configured = reparsed.configuringProvider(endpointValue: endpointValue)
        let output = configured.lines.joined(separator: "\n") + "\n"

        // 自检只覆盖本适配器支持的 TOML 子集，用以及早发现拼接错误。
        _ = try TOMLDocument.parse(output.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init))
        return Data(output.utf8)
    }

    private static let providerPath = ["model_providers", "ezswitch"]
    private static let topLevelKeys = ["model", "model_provider"]
    private static let conflictingProviderKeys: Set<String> = [
        "env_key", "requires_openai_auth", "env_http_headers", "http_headers_helper", "auth",
    ]
    private static let providerFieldNames = [
        "name",
        "base_url",
        "wire_api",
        "experimental_bearer_token",
    ]

    private enum ScanMode {
        case normal
        case basicString
        case literalString
    }

    private struct Assignment {
        let key: String
        let path: [String]
        let lineRange: ClosedRange<Int>
        let valueColumn: Int
        let isSimpleString: Bool
    }

    private struct TOMLDocument {
        var lines: [String]
        let firstTableIndex: Int?
        let topLevelAssignments: [String: Assignment]
        let providerHeaderIndex: Int?
        let providerAssignments: [String: Assignment]
        let assignments: [[String]: Assignment]
        let tables: Set<[String]>

        static func parse(_ lines: [String]) throws -> TOMLDocument {
            var firstTableIndex: Int?
            var currentTable: [String]?
            var topLevelAssignments: [String: Assignment] = [:]
            var providerHeaderIndex: Int?
            var providerAssignments: [String: Assignment] = [:]
            var assignments: [[String]: Assignment] = [:]
            var tables: Set<[String]> = []

            var lineIndex = 0
            while lineIndex < lines.count {
                let rawLine = lines[lineIndex]
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    lineIndex += 1
                    continue
                }

                if trimmed.hasPrefix("[[") {
                    throw CodexHarnessConfigError.unsupportedSyntax("表数组 `[[...]]` 未支持。")
                }

                if trimmed.hasPrefix("[") {
                    let path = try parseTableHeader(rawLine)
                    if tables.contains(path) {
                        throw CodexHarnessConfigError.conflict("重复的 table `\(path.joined(separator: "."))`。")
                    }
                    for existing in tables where existing.count > path.count &&
                        Array(existing.prefix(path.count)) == path {
                        throw CodexHarnessConfigError.conflict(
                            "table `\(path.joined(separator: "."))` 在子 table 之后重复出现。"
                        )
                    }
                    for existingPath in assignments.keys where existingPath == path ||
                        existingPath.count < path.count && Array(path.prefix(existingPath.count)) == existingPath {
                        throw CodexHarnessConfigError.conflict(
                            "table `\(path.joined(separator: "."))` 与已有 key 冲突。"
                        )
                    }

                    if path.count > CodexHarnessConfig.providerPath.count,
                       Array(path.prefix(CodexHarnessConfig.providerPath.count)) == CodexHarnessConfig.providerPath {
                        throw CodexHarnessConfigError.unsupportedSyntax(
                            "EZ Switch provider table 包含未支持的子 table。"
                        )
                    }

                    tables.insert(path)
                    if firstTableIndex == nil { firstTableIndex = lineIndex }
                    if path == CodexHarnessConfig.providerPath {
                        if providerHeaderIndex != nil {
                            throw CodexHarnessConfigError.conflict("重复的 `[model_providers.ezswitch]`。")
                        }
                        providerHeaderIndex = lineIndex
                    }
                    currentTable = path
                    lineIndex += 1
                    continue
                }

                let assignment = try parseAssignment(lines, startingAt: lineIndex)
                let fullPath = (currentTable ?? []) + [assignment.key]
                if assignments[fullPath] != nil {
                    throw CodexHarnessConfigError.conflict(
                        "重复的 key `\(fullPath.joined(separator: "."))`。"
                    )
                }
                if tables.contains(fullPath) {
                    throw CodexHarnessConfigError.conflict(
                        "key `\(fullPath.joined(separator: "."))` 与已有 table 冲突。"
                    )
                }
                for tablePath in tables where tablePath.count > fullPath.count &&
                    Array(tablePath.prefix(fullPath.count)) == fullPath {
                    throw CodexHarnessConfigError.conflict(
                        "key `\(fullPath.joined(separator: "."))` 与子 table 冲突。"
                    )
                }

                assignments[fullPath] = assignment
                if currentTable == nil, CodexHarnessConfig.topLevelKeys.contains(assignment.key) {
                    guard assignment.isSimpleString else {
                        throw CodexHarnessConfigError.conflict(
                            "顶层 `\(assignment.key)` 必须是单行字符串。"
                        )
                    }
                    topLevelAssignments[assignment.key] = assignment
                }
                if currentTable == CodexHarnessConfig.providerPath,
                   CodexHarnessConfig.providerFieldNames.contains(assignment.key) {
                    guard assignment.isSimpleString else {
                        throw CodexHarnessConfigError.conflict(
                            "`[model_providers.ezswitch].\(assignment.key)` 必须是单行字符串。"
                        )
                    }
                    providerAssignments[assignment.key] = assignment
                }
                if currentTable == CodexHarnessConfig.providerPath,
                   CodexHarnessConfig.conflictingProviderKeys.contains(assignment.key) {
                    throw CodexHarnessConfigError.conflict(
                        "已有 `[model_providers.ezswitch].\(assignment.key)`，请先手动处理认证配置。"
                    )
                }
                lineIndex = assignment.lineRange.upperBound + 1
            }

            return TOMLDocument(
                lines: lines,
                firstTableIndex: firstTableIndex,
                topLevelAssignments: topLevelAssignments,
                providerHeaderIndex: providerHeaderIndex,
                providerAssignments: providerAssignments,
                assignments: assignments,
                tables: tables
            )
        }

        func replacingTopLevel(modelValue: String, providerValue: String) -> TOMLDocument {
            var updatedLines = lines
            let desired = [
                ("model", modelValue),
                ("model_provider", providerValue),
            ]
            var missing: [(String, String)] = []

            for (key, value) in desired {
                if let assignment = topLevelAssignments[key] {
                    updatedLines[assignment.lineRange.lowerBound] = replacingValue(
                        in: updatedLines[assignment.lineRange.lowerBound],
                        key: key,
                        value: value,
                        assignment: assignment
                    )
                } else {
                    missing.append((key, value))
                }
            }

            if !missing.isEmpty {
                let insertIndex: Int
                if let provider = topLevelAssignments["model_provider"] {
                    insertIndex = provider.lineRange.lowerBound
                } else if let model = topLevelAssignments["model"] {
                    insertIndex = model.lineRange.upperBound + 1
                } else if let firstTableIndex {
                    let priorStatements = assignments.values.filter { $0.lineRange.upperBound < firstTableIndex }
                    insertIndex = priorStatements.map { $0.lineRange.upperBound + 1 }.max() ?? firstTableIndex
                } else {
                    insertIndex = updatedLines.count
                }
                updatedLines.insert(
                    contentsOf: missing.map { "\($0.0) = \($0.1)" },
                    at: insertIndex
                )
            }

            return TOMLDocument(
                lines: updatedLines,
                firstTableIndex: firstTableIndex,
                topLevelAssignments: topLevelAssignments,
                providerHeaderIndex: providerHeaderIndex,
                providerAssignments: providerAssignments,
                assignments: assignments,
                tables: tables
            )
        }

        func configuringProvider(endpointValue: String) -> TOMLDocument {
            var updatedLines = lines
            let desired = [
                ("name", "\"EZ Switch\""),
                ("base_url", endpointValue),
                ("wire_api", "\"responses\""),
                ("experimental_bearer_token", "\"ez-switch-local\""),
            ]
            var missing: [(String, String)] = []

            for (key, value) in desired {
                if let assignment = providerAssignments[key] {
                    updatedLines[assignment.lineRange.lowerBound] = replacingValue(
                        in: updatedLines[assignment.lineRange.lowerBound],
                        key: key,
                        value: value,
                        assignment: assignment
                    )
                } else {
                    missing.append((key, value))
                }
            }

            if let providerHeaderIndex {
                if !missing.isEmpty {
                    let insertIndex = providerAssignments.values
                        .map { $0.lineRange.upperBound + 1 }
                        .max() ?? (providerHeaderIndex + 1)
                    updatedLines.insert(
                        contentsOf: missing.map { "\($0.0) = \($0.1)" },
                        at: insertIndex
                    )
                }
            } else {
                if !updatedLines.isEmpty, updatedLines.last?.isEmpty == false {
                    updatedLines.append("")
                }
                updatedLines.append("[model_providers.ezswitch]")
                updatedLines.append(contentsOf: desired.map { "\($0.0) = \($0.1)" })
            }

            return TOMLDocument(
                lines: updatedLines,
                firstTableIndex: firstTableIndex,
                topLevelAssignments: topLevelAssignments,
                providerHeaderIndex: providerHeaderIndex,
                providerAssignments: providerAssignments,
                assignments: assignments,
                tables: tables
            )
        }

        private func replacingValue(
            in line: String,
            key: String,
            value: String,
            assignment: Assignment
        ) -> String {
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let characters = Array(line)
            let suffix = String(characters.dropFirst(assignment.valueColumn))
            let comment = commentSuffix(in: suffix)
            return "\(indent)\(key) = \(value)\(comment)"
        }
    }

    private static func decodeLines(_ original: Data?) throws -> [String] {
        guard let original, !original.isEmpty else { return [] }
        guard var text = String(data: original, encoding: .utf8) else {
            throw CodexHarnessConfigError.invalidUTF8
        }
        if text.contains("\r") {
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
            guard !text.contains("\r") else {
                throw CodexHarnessConfigError.unsupportedSyntax("不支持单独的 CR 换行。")
            }
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n"), lines.last == "" { lines.removeLast() }
        if !lines.isEmpty, lines[0].hasPrefix("\u{FEFF}") { lines[0].removeFirst() }
        return lines
    }

    private static func parseTableHeader(_ rawLine: String) throws -> [String] {
        let characters = Array(rawLine)
        var index = 0
        skipWhitespace(characters, index: &index)
        guard index < characters.count, characters[index] == "[" else {
            throw CodexHarnessConfigError.unsupportedSyntax("table header 格式无效。")
        }
        index += 1
        if index < characters.count, characters[index] == "[" {
            throw CodexHarnessConfigError.unsupportedSyntax("表数组 `[[...]]` 未支持。")
        }

        let contentStart = index
        var mode = ScanMode.normal
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            if mode == .basicString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    mode = .normal
                }
            } else if mode == .literalString {
                if character == "'" { mode = .normal }
            } else if character == "\"" {
                mode = .basicString
            } else if character == "'" {
                mode = .literalString
            } else if character == "]" {
                break
            } else if character == "#" {
                throw CodexHarnessConfigError.unsupportedSyntax("table header 中不能出现注释。")
            }
            index += 1
        }

        guard index < characters.count, characters[index] == "]", mode == .normal else {
            throw CodexHarnessConfigError.unsupportedSyntax("table header 缺少闭合 `]`。")
        }
        let content = String(characters[contentStart..<index])
        index += 1
        skipWhitespace(characters, index: &index)
        if index < characters.count, characters[index] != "#" {
            throw CodexHarnessConfigError.unsupportedSyntax("table header 后存在多余内容。")
        }
        return try parseKeyPath(content)
    }

    private static func parseAssignment(_ lines: [String], startingAt lineIndex: Int) throws -> Assignment {
        let rawLine = lines[lineIndex]
        let characters = Array(rawLine)
        guard let equalIndex = findUnquotedEqual(characters) else {
            throw CodexHarnessConfigError.unsupportedSyntax("无法识别的 TOML 行。")
        }
        let keyText = String(characters[..<equalIndex]).trimmingCharacters(in: .whitespaces)
        let key = try parseSimpleKey(keyText)
        let valueColumn = equalIndex + 1
        let scanned = try scanValue(lines, startingAt: lineIndex, column: valueColumn)
        return Assignment(
            key: key,
            path: [key],
            lineRange: lineIndex...scanned.endLine,
            valueColumn: valueColumn,
            isSimpleString: scanned.isSimpleString
        )
    }

    private static func findUnquotedEqual(_ characters: [Character]) -> Int? {
        var mode = ScanMode.normal
        var escaped = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if mode == .basicString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    mode = .normal
                }
            } else if mode == .literalString {
                if character == "'" { mode = .normal }
            } else if character == "\"" {
                mode = .basicString
            } else if character == "'" {
                mode = .literalString
            } else if character == "=" {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func scanValue(
        _ lines: [String],
        startingAt startLine: Int,
        column: Int
    ) throws -> (endLine: Int, isSimpleString: Bool) {
        var squareDepth = 0
        var braceDepth = 0
        var mode = ScanMode.normal
        var escaped = false
        var sawValue = false
        var firstValueColumn: Int?

        for lineIndex in startLine..<lines.count {
            let characters = Array(lines[lineIndex])
            var index = lineIndex == startLine ? column : 0
            while index < characters.count {
                let character = characters[index]
                if firstValueColumn == nil, !character.isWhitespace, character != "#" {
                    firstValueColumn = index
                }

                if mode == .basicString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        mode = .normal
                    } else if character.isControlCharacter, character != "\t" {
                        throw CodexHarnessConfigError.unsupportedSyntax("basic string 中包含未转义控制字符。")
                    }
                } else if mode == .literalString {
                    if character == "'" {
                        mode = .normal
                    } else if character.isControlCharacter, character != "\t" {
                        throw CodexHarnessConfigError.unsupportedSyntax("literal string 中包含控制字符。")
                    }
                } else if character == "#" {
                    break
                } else if character == "\"" {
                    if isTripleQuote(characters, at: index, quote: "\"") {
                        throw CodexHarnessConfigError.unsupportedSyntax("多行字符串暂不支持。")
                    }
                    mode = .basicString
                    sawValue = true
                } else if character == "'" {
                    if isTripleQuote(characters, at: index, quote: "'") {
                        throw CodexHarnessConfigError.unsupportedSyntax("多行字符串暂不支持。")
                    }
                    mode = .literalString
                    sawValue = true
                } else if character == "[" {
                    squareDepth += 1
                    sawValue = true
                } else if character == "]" {
                    squareDepth -= 1
                    guard squareDepth >= 0 else {
                        throw CodexHarnessConfigError.unsupportedSyntax("数组括号不匹配。")
                    }
                } else if character == "{" {
                    braceDepth += 1
                    sawValue = true
                } else if character == "}" {
                    braceDepth -= 1
                    guard braceDepth >= 0 else {
                        throw CodexHarnessConfigError.unsupportedSyntax("inline table 括号不匹配。")
                    }
                } else if !character.isWhitespace {
                    sawValue = true
                }
                index += 1
            }

            if mode != .normal {
                throw CodexHarnessConfigError.unsupportedSyntax("字符串必须在本行闭合。")
            }
            if braceDepth > 0 {
                throw CodexHarnessConfigError.unsupportedSyntax("inline table 不能跨行。")
            }
            if squareDepth == 0, lineIndex == startLine {
                guard sawValue else {
                    throw CodexHarnessConfigError.unsupportedSyntax("key 后没有值。")
                }
                let simpleString = firstValueColumn.flatMap {
                    isSimpleStringValue(characters, startingAt: $0)
                } ?? false
                return (lineIndex, simpleString)
            }
            if squareDepth == 0 {
                return (lineIndex, false)
            }
        }

        throw CodexHarnessConfigError.unsupportedSyntax("值没有在文件结束前闭合。")
    }

    private static func isSimpleStringValue(_ characters: [Character], startingAt index: Int) -> Bool {
        guard index < characters.count, characters[index] == "\"" || characters[index] == "'" else {
            return false
        }
        let quote = characters[index]
        var cursor = index + 1
        var escaped = false
        while cursor < characters.count {
            let character = characters[cursor]
            if quote == "\"" {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == quote {
                    return onlyWhitespaceOrComment(characters, after: cursor + 1)
                }
            } else if character == quote {
                return onlyWhitespaceOrComment(characters, after: cursor + 1)
            }
            cursor += 1
        }
        return false
    }

    private static func onlyWhitespaceOrComment(_ characters: [Character], after index: Int) -> Bool {
        var cursor = index
        while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
        return cursor == characters.count || characters[cursor] == "#"
    }

    private static func commentSuffix(in value: String) -> String {
        let characters = Array(value)
        var mode = ScanMode.normal
        var escaped = false
        for index in characters.indices {
            let character = characters[index]
            if mode == .basicString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    mode = .normal
                }
            } else if mode == .literalString {
                if character == "'" { mode = .normal }
            } else if character == "\"" {
                mode = .basicString
            } else if character == "'" {
                mode = .literalString
            } else if character == "#" {
                var commentStart = index
                while commentStart > 0, characters[commentStart - 1].isWhitespace {
                    commentStart -= 1
                }
                return String(characters[commentStart...])
            }
        }
        return ""
    }

    private static func parseKeyPath(_ text: String) throws -> [String] {
        let characters = Array(text)
        var index = 0
        var parts: [String] = []
        skipWhitespace(characters, index: &index)
        while index < characters.count {
            let part = try parseKeySegment(characters, index: &index)
            parts.append(part)
            skipWhitespace(characters, index: &index)
            if index == characters.count { break }
            guard characters[index] == "." else {
                throw CodexHarnessConfigError.unsupportedSyntax("key 只能包含一个段；点号 key 未支持。")
            }
            index += 1
            skipWhitespace(characters, index: &index)
            guard index < characters.count else {
                throw CodexHarnessConfigError.unsupportedSyntax("点号后缺少 key。")
            }
        }
        guard !parts.isEmpty else {
            throw CodexHarnessConfigError.unsupportedSyntax("key 不能为空。")
        }
        return parts
    }

    private static func parseSimpleKey(_ text: String) throws -> String {
        let parts = try parseKeyPath(text)
        guard parts.count == 1 else {
            throw CodexHarnessConfigError.unsupportedSyntax("点号 key 未支持。")
        }
        return parts[0]
    }

    private static func parseKeySegment(_ characters: [Character], index: inout Int) throws -> String {
        guard index < characters.count else {
            throw CodexHarnessConfigError.unsupportedSyntax("key 不能为空。")
        }
        if characters[index] == "\"" {
            return try parseBasicString(characters, index: &index)
        }
        if characters[index] == "'" {
            return try parseLiteralString(characters, index: &index)
        }

        let start = index
        while index < characters.count {
            let character = characters[index]
            if character.isLetter || character.isNumber || character == "_" || character == "-" {
                index += 1
            } else {
                break
            }
        }
        guard index > start else {
            throw CodexHarnessConfigError.unsupportedSyntax("key 段格式无效。")
        }
        return String(characters[start..<index])
    }

    private static func parseBasicString(_ characters: [Character], index: inout Int) throws -> String {
        guard index < characters.count, characters[index] == "\"" else {
            throw CodexHarnessConfigError.unsupportedSyntax("basic string 缺少起始引号。")
        }
        index += 1
        var value = ""
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                index += 1
                return value
            }
            if character == "\\" {
                index += 1
                guard index < characters.count else {
                    throw CodexHarnessConfigError.unsupportedSyntax("字符串转义不完整。")
                }
                let escaped = characters[index]
                switch escaped {
                case "b": value.append("\u{8}")
                case "t": value.append("\t")
                case "n": value.append("\n")
                case "f": value.append("\u{C}")
                case "r": value.append("\r")
                case "\"": value.append("\"")
                case "\\": value.append("\\")
                case "u", "U":
                    let count = escaped == "u" ? 4 : 8
                    guard index + count < characters.count else {
                        throw CodexHarnessConfigError.unsupportedSyntax("Unicode 转义不完整。")
                    }
                    let digits = String(characters[(index + 1)...(index + count)])
                    guard let scalarValue = UInt32(digits, radix: 16),
                          let scalar = UnicodeScalar(scalarValue) else {
                        throw CodexHarnessConfigError.unsupportedSyntax("Unicode 转义无效。")
                    }
                    value.unicodeScalars.append(scalar)
                    index += count
                default:
                    throw CodexHarnessConfigError.unsupportedSyntax("不支持的字符串转义 `\\\(escaped)`。")
                }
            } else {
                if character.isControlCharacter, character != "\t" {
                    throw CodexHarnessConfigError.unsupportedSyntax("basic string 中包含控制字符。")
                }
                value.append(character)
            }
            index += 1
        }
        throw CodexHarnessConfigError.unsupportedSyntax("basic string 缺少结束引号。")
    }

    private static func parseLiteralString(_ characters: [Character], index: inout Int) throws -> String {
        guard index < characters.count, characters[index] == "'" else {
            throw CodexHarnessConfigError.unsupportedSyntax("literal string 缺少起始引号。")
        }
        index += 1
        var value = ""
        while index < characters.count {
            let character = characters[index]
            if character == "'" {
                index += 1
                return value
            }
            if character.isControlCharacter, character != "\t" {
                throw CodexHarnessConfigError.unsupportedSyntax("literal string 中包含控制字符。")
            }
            value.append(character)
            index += 1
        }
        throw CodexHarnessConfigError.unsupportedSyntax("literal string 缺少结束引号。")
    }

    private static func skipWhitespace(_ characters: [Character], index: inout Int) {
        while index < characters.count, characters[index].isWhitespace { index += 1 }
    }

    private static func isTripleQuote(_ characters: [Character], at index: Int, quote: Character) -> Bool {
        guard index + 2 < characters.count else { return false }
        return characters[index + 1] == quote && characters[index + 2] == quote
    }

    private static func tomlString(_ value: String) throws -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: output += "\\\""
            case 0x5C: output += "\\\\"
            case 0x08: output += "\\b"
            case 0x09: output += "\\t"
            case 0x0A: output += "\\n"
            case 0x0C: output += "\\f"
            case 0x0D: output += "\\r"
            case 0x00...0x1F, 0x7F:
                let digits = String(scalar.value, radix: 16, uppercase: true)
                output += "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
        return output
    }
}

private extension Character {
    var isControlCharacter: Bool {
        unicodeScalars.allSatisfy { $0.value < 0x20 || $0.value == 0x7F }
    }
}
