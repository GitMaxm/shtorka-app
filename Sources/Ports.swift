import AppKit
import Darwin

/// Запущенный локальный сервер (npm run dev, python -m http.server, postgres…).
struct DevServer: Identifiable, Equatable {
    let pid: Int32
    let port: Int
    let command: String
    /// «Next.js», «Vite», «Python»… — по командной строке процесса.
    let kind: String
    /// Рабочая папка процесса — обычно это папка проекта.
    let folder: URL?
    /// Процессы внутри приложений (Docker, Postgres.app) не останавливаем: убьём всё приложение.
    let canStop: Bool

    var id: String { "\(pid):\(port)" }
    var url: URL { URL(string: "http://localhost:\(port)")! }
    var subtitle: String {
        if kind == "Docker" { return "контейнер" }
        return folder?.lastPathComponent ?? command
    }
}

@MainActor
final class PortsStore: ObservableObject {
    @Published private(set) var servers: [DevServer] = []
    private var generation = 0

    func refresh() async {
        generation += 1
        let mine = generation
        let result = await Task.detached(priority: .userInitiated) { Self.scan() }.value
        // Пока сканировали, мог начаться более свежий поиск (например, после «Остановить») — старый результат не нужен.
        guard mine == generation else { return }
        let alive = result.filter { kill($0.pid, 0) == 0 }
        if alive != servers { servers = alive }
    }

    /// Мягко останавливает процесс, а если он не слушается две секунды — принудительно.
    func stop(_ server: DevServer) async -> Bool {
        generation += 1                                  // уже идущие поиски устарели
        servers.removeAll { $0.pid == server.pid }       // карточка пропадает сразу
        kill(server.pid, SIGTERM)
        for _ in 0..<20 where kill(server.pid, 0) == 0 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if kill(server.pid, 0) == 0 { kill(server.pid, SIGKILL) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        await refresh()
        return !servers.contains { $0.pid == server.pid }
    }

    func setPreviewServers(_ servers: [DevServer]) { self.servers = servers }

    // MARK: - Поиск серверов

    nonisolated static func scan() -> [DevServer] {
        let output = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "+c", "0", "-Fpcn"])
        let me = ProcessInfo.processInfo.processIdentifier
        var result: [DevServer] = []
        var seen = Set<String>()
        var pid: Int32 = 0
        var command = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value) ?? 0
            case "c":
                command = value
            case "n":
                // «*:3000», «127.0.0.1:5173», «[::1]:3000»
                guard let port = value.split(separator: ":").last.flatMap({ Int($0) }),
                      pid != me, seen.insert("\(pid):\(port)").inserted,
                      let canStop = stoppability(of: pid) else { continue }
                let args = arguments(of: pid)
                result.append(DevServer(pid: pid, port: port, command: command,
                                        kind: kind(command: command, arguments: args),
                                        folder: projectFolder(of: pid), canStop: canStop))
            default:
                break
            }
        }
        return result.sorted { $0.port < $1.port }
    }

    /// Системные службы и обычные программы (AirPlay, Spotify, WebStorm, Figma…) не показываем —
    /// только то, что запущено из терминала или Homebrew, плюс Docker и подобные.
    /// nil — не показывать, иначе — можно ли останавливать процесс.
    nonisolated private static func stoppability(of pid: Int32) -> Bool? {
        guard let path = executablePath(pid) else { return nil }
        let system = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
        if system.contains(where: path.hasPrefix) { return nil }
        guard path.contains(".app/Contents/") else { return true }
        // Python из Xcode и Homebrew тоже живёт в Python.app — это обычный скрипт.
        if path.contains("/Python.app/") { return true }
        let devApps = ["Docker.app", "OrbStack.app", "Postgres.app", "MAMP", "Local.app", "Herd.app", "DBngin.app"]
        return devApps.contains { path.contains($0) } ? false : nil
    }

    /// Папка проекта — рабочая папка процесса, если это не служебная папка в ~/Library.
    nonisolated private static func projectFolder(of pid: Int32) -> URL? {
        guard let folder = workingDirectory(of: pid) else { return nil }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        return folder.path.hasPrefix(library) ? nil : folder
    }

    nonisolated private static func kind(command: String, arguments: [String]) -> String {
        let haystack = ([command] + arguments).joined(separator: " ").lowercased()
        let known: [(needles: [String], name: String)] = [
            (["next-server", "next/dist", ".bin/next"], "Next.js"),
            (["nuxt"], "Nuxt"),
            (["astro"], "Astro"),
            (["storybook"], "Storybook"),
            (["react-scripts"], "Create React App"),
            (["@angular", "ng serve"], "Angular"),
            (["svelte-kit", "sveltekit"], "SvelteKit"),
            (["remix"], "Remix"),
            (["expo"], "Expo"),
            (["/vite/", ".bin/vite", "vite.js"], "Vite"),
            (["webpack"], "Webpack"),
            (["json-server"], "json-server"),
            (["http.server"], "Python http.server"),
            (["manage.py", "django"], "Django"),
            (["uvicorn"], "Uvicorn"),
            (["flask"], "Flask"),
            (["rails", "puma"], "Rails"),
            (["postgres"], "PostgreSQL"),
            (["redis-server"], "Redis"),
            (["mongod"], "MongoDB"),
            (["mysqld"], "MySQL"),
            (["docker", "orbstack"], "Docker"),
        ]
        if let match = known.first(where: { entry in entry.needles.contains { haystack.contains($0) } }) {
            return match.name
        }
        let name = command.split(separator: " ").first.map(String.init) ?? command
        return name.isEmpty ? "Сервер" : name
    }

    // MARK: - Сведения о процессе

    nonisolated private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    nonisolated private static func workingDirectory(of pid: Int32) -> URL? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty || path == "/" ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Командная строка процесса (sysctl KERN_PROCARGS2).
    nonisolated private static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }   // путь к программе
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
