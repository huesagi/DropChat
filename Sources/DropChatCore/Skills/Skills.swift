import Foundation

/// An Agent Skill: a folder with a `SKILL.md` whose YAML frontmatter names
/// and describes it. The model sees every skill's name and description, and
/// loads the full instructions (and any bundled files) only when it needs
/// them.
public struct Skill: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var directory: URL
    public var instructionsURL: URL

    public init(name: String, description: String, directory: URL, instructionsURL: URL) {
        self.name = name
        self.description = description
        self.directory = directory
        self.instructionsURL = instructionsURL
    }
}

/// The subset of YAML that skill frontmatter uses: `key: value` pairs,
/// quoted or not, plus folded (`>`) and literal (`|`) blocks.
public enum Frontmatter {
    public static func split(_ document: String) -> (fields: [String: String], body: String) {
        let normalized = document.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return ([:], normalized) }
        let rest = normalized.dropFirst(4)
        guard let end = rest.range(of: "\n---") else { return ([:], normalized) }
        let header = String(rest[..<end.lowerBound])
        var body = String(rest[end.upperBound...])
        if let newline = body.firstIndex(of: "\n") { body = String(body[body.index(after: newline)...]) } else { body = "" }
        return (parse(header), body)
    }

    public static func parse(_ header: String) -> [String: String] {
        var fields: [String: String] = [:]
        let lines = header.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.hasPrefix("#") else { continue }

            if value == ">" || value == "|" || value == ">-" || value == "|-" {
                var block: [String] = []
                while index < lines.count, lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") || lines[index].isEmpty {
                    block.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = value.hasPrefix(">") ? block.joined(separator: " ") : block.joined(separator: "\n")
            } else if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2) || (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "''", with: "'")
            }
            fields[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fields
    }
}

public enum SkillLoader {
    /// Finds skills one level below each directory (`<dir>/<skill>/SKILL.md`)
    /// and in the directory itself. Runs file I/O, so call it off the main actor.
    public static func discover(in directories: [URL]) -> [Skill] {
        var skills: [String: Skill] = [:]
        let fileManager = FileManager.default
        for root in directories {
            var candidates = [root]
            if let children = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                candidates += children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }
            for directory in candidates {
                let file = directory.appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let (fields, _) = Frontmatter.split(text)
                let name = fields["name"] ?? directory.lastPathComponent
                guard skills[name] == nil else { continue }
                skills[name] = Skill(
                    name: name,
                    description: fields["description"] ?? "",
                    directory: directory.standardizedFileURL,
                    instructionsURL: file
                )
            }
        }
        return skills.values.sorted { $0.name < $1.name }
    }

    /// Resolves `relative` inside the skill's folder, refusing anything that
    /// escapes it (`..`, absolute paths, symlinks out).
    public static func resolve(_ relative: String, in skill: Skill) throws -> URL {
        let root = skill.directory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw ToolArgumentError.invalid("path", "it must stay inside the skill's folder")
        }
        return candidate
    }

    /// Every file in the skill, relative to its folder.
    public static func listFiles(in skill: Skill, limit: Int = 200) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: skill.directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [String] = []
        let prefix = skill.directory.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            files.append(url.standardizedFileURL.path.replacingOccurrences(of: prefix, with: ""))
            if files.count >= limit { break }
        }
        return files.sorted()
    }
}

/// Exposes skills as tools and lists them in the system prompt.
public final class SkillToolSource: ToolSource, PromptContributor, @unchecked Sendable {
    public let id = "skills"
    public let displayName = "Skills"

    let directories: [URL]
    let allowsScripts: Bool
    private let lock = SyncLock()
    private var skills: [Skill] = []

    public init(directories: [URL], allowsScripts: Bool) {
        self.directories = directories
        self.allowsScripts = allowsScripts
    }

    public func start() async {
        await reload()
    }

    public func reload() async {
        let directories = self.directories
        let found = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: SkillLoader.discover(in: directories))
            }
        }
        lock.withLock { skills = found }
    }

    public var currentSkills: [Skill] { lock.withLock { skills } }

    public func status() async -> ToolSourceStatus {
        let count = currentSkills.count
        return .ready(detail: count == 1 ? "1 skill" : "\(count) skills")
    }

    public func systemPromptSection() async -> String? {
        let skills = currentSkills
        guard !skills.isEmpty else { return nil }
        let list = skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        return """
        You have agent skills: packaged instructions for specific tasks. When a request matches a skill's \
        description, call load_skill with its name before you start, then follow its instructions. \
        Skills may reference bundled files; read them with read_skill_file\(allowsScripts ? " and run bundled scripts with run_skill_script" : "").

        Available skills:
        \(list)
        """
    }

    func skill(named name: String) throws -> Skill {
        guard let skill = currentSkills.first(where: { $0.name == name }) else {
            throw ToolArgumentError.invalid("name", "there is no skill called \(name)")
        }
        return skill
    }

    public func tools() async -> [any ChatTool] {
        guard !currentSkills.isEmpty else { return [] }
        var tools: [any ChatTool] = [
            FunctionTool(
                spec: ToolSpec(
                    name: "load_skill",
                    description: "Load a skill's full instructions (its SKILL.md) and the list of files it bundles.",
                    inputSchema: ["type": "object", "properties": ["name": ["type": "string", "description": "The skill's name."]], "required": ["name"]]
                ),
                displayName: "Load a skill",
                sourceID: id,
                run: { [weak self] arguments, _ in
                    guard let self else { return .error("Skills are not available.") }
                    let skill = try self.skill(named: try arguments.requiredString("name"))
                    let text = try await FileIO.readText(skill.instructionsURL, limit: 200_000)
                    let files = await FileIO.offMain { SkillLoader.listFiles(in: skill) }.filter { $0 != "SKILL.md" }
                    var output = "<skill name=\"\(skill.name)\" folder=\"\(skill.directory.path)\">\n\(text)\n</skill>"
                    if !files.isEmpty { output += "\n\nBundled files:\n" + files.map { "- \($0)" }.joined(separator: "\n") }
                    return ToolOutput(text: output)
                }
            ),
            FunctionTool(
                spec: ToolSpec(
                    name: "read_skill_file",
                    description: "Read a file bundled with a skill (a reference document, template or script source).",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "The skill's name."],
                            "path": ["type": "string", "description": "Path relative to the skill's folder."],
                        ],
                        "required": ["name", "path"],
                    ]
                ),
                displayName: "Read a skill file",
                sourceID: id,
                run: { [weak self] arguments, _ in
                    guard let self else { return .error("Skills are not available.") }
                    let skill = try self.skill(named: try arguments.requiredString("name"))
                    let url = try SkillLoader.resolve(try arguments.requiredString("path"), in: skill)
                    return ToolOutput(text: try await FileIO.readText(url, limit: 200_000))
                }
            ),
        ]
        if allowsScripts {
            tools.append(FunctionTool(
                spec: ToolSpec(
                    name: "run_skill_script",
                    description: "Run a script bundled with a skill, in the skill's folder. The user approves every run. Returns exit status, stdout and stderr.",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "The skill's name."],
                            "path": ["type": "string", "description": "Script path relative to the skill's folder."],
                            "arguments": ["type": "array", "items": ["type": "string"], "description": "Command-line arguments."],
                            "stdin": ["type": "string", "description": "Text to pass on standard input."],
                        ],
                        "required": ["name", "path"],
                    ]
                ),
                displayName: "Run a skill script",
                sourceID: id,
                approval: { arguments in
                    let path = arguments["path"]?.stringValue ?? "a script"
                    let name = arguments["name"]?.stringValue ?? "a skill"
                    let args = arguments["arguments"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ") ?? ""
                    return .always(reason: "Runs \(path)\(args.isEmpty ? "" : " \(args)") from the \(name) skill on your Mac.")
                },
                run: { [weak self] arguments, _ in
                    guard let self else { return .error("Skills are not available.") }
                    let skill = try self.skill(named: try arguments.requiredString("name"))
                    let script = try SkillLoader.resolve(try arguments.requiredString("path"), in: skill)
                    let extra = arguments["arguments"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    let (executable, argv) = try ScriptInterpreter.command(for: script, arguments: extra)
                    let result = try await ProcessRunner.run(
                        executable,
                        arguments: argv,
                        workingDirectory: skill.directory,
                        stdin: arguments["stdin"]?.stringValue.map { Data($0.utf8) },
                        timeout: .seconds(120)
                    )
                    var text = "exit status: \(result.status)\(result.timedOut ? " (stopped after 120 seconds)" : "")"
                    if !result.stdout.isEmpty { text += "\n\nstdout:\n\(result.stdout)" }
                    if !result.stderr.isEmpty { text += "\n\nstderr:\n\(result.stderr)" }
                    return ToolOutput(text: text, isError: result.status != 0)
                }
            ))
        }
        return tools
    }
}

enum ScriptInterpreter {
    static func command(for script: URL, arguments: [String]) throws -> (URL, [String]) {
        let environment = ProcessRunner.augmentedEnvironment()
        let interpreter: String?
        switch script.pathExtension.lowercased() {
        case "py": interpreter = "python3"
        case "sh", "bash": interpreter = "bash"
        case "zsh": interpreter = "zsh"
        case "js", "mjs", "cjs": interpreter = "node"
        case "ts": interpreter = "bun"
        case "rb": interpreter = "ruby"
        case "pl": interpreter = "perl"
        case "swift": interpreter = "swift"
        default: interpreter = nil
        }
        if let interpreter {
            guard let executable = ProcessRunner.resolveExecutable(interpreter, environment: environment) else {
                throw ToolArgumentError.invalid("path", "\(interpreter) is not installed")
            }
            return (executable, [script.path] + arguments)
        }
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw ToolArgumentError.invalid("path", "the file is not executable and its type is unknown")
        }
        return (script, arguments)
    }
}

/// File reads off the main actor.
public enum FileIO {
    public static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    public static func offMainThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    public static func readText(_ url: URL, limit: Int) async throws -> String {
        try await offMainThrowing({
            let data = try Data(contentsOf: url)
            let text = String(decoding: data.prefix(limit), as: UTF8.self)
            return data.count > limit ? text + "\n\n[Truncated at \(limit) bytes of \(data.count).]" : text
        })
    }
}
