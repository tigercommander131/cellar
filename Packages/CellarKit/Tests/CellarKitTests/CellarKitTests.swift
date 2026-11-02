import Foundation
import Testing
@testable import CellarKit

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "cellar-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct VDFTests {
    @Test func parsesNestedObjectsCaseInsensitively() throws {
        let vdf = try VDF.parse("""
        "AppState"
        {
            "appid"     "730"
            "name"      "Counter-Strike 2"
            "StateFlags"    "4"
            "UserConfig" { "language" "english" }
        }
        """)
        #expect(vdf["appstate"]?["APPID"]?.string == "730")
        #expect(vdf["AppState"]?["UserConfig"]?["language"]?.string == "english")
    }

    @Test func handlesEscapesCommentsAndConditionals() throws {
        let vdf = try VDF.parse(#"""
        // comment
        "libraryfolders" { "0" { "path" "C:\\Program Files (x86)\\Steam" } "x" "1" [$WIN32] }
        """#)
        #expect(vdf["libraryfolders"]?["0"]?["path"]?.string == #"C:\Program Files (x86)\Steam"#)
        #expect(vdf["libraryfolders"]?["x"]?.string == "1")
    }

    @Test func rejectsUnterminatedInput() {
        #expect(throws: CellarError.self) { try VDF.parse(#""a" { "b" "c""#) }
    }
}

@Suite struct SteamTests {
    @Test func libraryReadsManifests() throws {
        let root = try tempDir()
        let steam = Steam(bottle: Bottle(paths: CellarPaths(root: root), name: "steam"))
        let apps = steam.steamDir.appending(path: "steamapps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try #""AppState" { "appid" "730" "name" "Counter-Strike 2" "installdir" "Counter-Strike Global Offensive" "StateFlags" "4" "SizeOnDisk" "100" }"#
            .write(to: apps.appending(path: "appmanifest_730.acf"), atomically: true, encoding: .utf8)
        try #""AppState" { "appid" "228980" "name" "Steamworks Common Redistributables" "StateFlags" "4" }"#
            .write(to: apps.appending(path: "appmanifest_228980.acf"), atomically: true, encoding: .utf8)
        try #""AppState" { "appid" "9" "name" "Big" "StateFlags" "1026" "BytesToDownload" "200" "BytesDownloaded" "50" }"#
            .write(to: apps.appending(path: "appmanifest_9.acf"), atomically: true, encoding: .utf8)

        let list = steam.apps()
        #expect(list.map(\.id) == ["9", "730"])
        #expect(list[1].isInstalled)
        #expect(list[0].isUpdating)
        #expect(list[0].downloadProgress == 0.25)
    }

    @Test func playArguments() {
        let args = Steam.arguments(.play(appID: "730", args: ["-novid"]), steamArgs: ["-no-cef-sandbox"])
        #expect(args.first == #"C:\Program Files (x86)\Steam\steam.exe"#)
        #expect(args.contains("-cef-disable-gpu"))
        #expect(Array(args.suffix(3)) == ["-applaunch", "730", "-novid"])
        #expect(args.firstIndex(of: "-no-cef-sandbox")! < args.firstIndex(of: "-applaunch")!)
        #expect(Steam.arguments(.play(appID: "1", args: []), hideSteam: true).contains("-silent"))
        #expect(Steam.arguments(.install(appID: "730")).last == "steam://install/730")
    }

    @Test func runningAppsComeFromInstallFolders() {
        func app(_ id: String, _ dir: String) -> SteamApp {
            SteamApp(id: id, name: dir, installDir: dir, libraryPath: "", stateFlags: 4, sizeOnDisk: 0, bytesToDownload: 0, bytesDownloaded: 0)
        }
        let apps = [app("730", "Counter-Strike Global Offensive"), app("9", "Teardown"), app("1", "Tear")]
        let running = [#"C:\Program Files (x86)\Steam\steamapps\common\Teardown\teardown.exe"#, #"C:\windows\system32\services.exe"#]
        #expect(Steam.appIDs(apps, runningFrom: running) == ["9"])
    }
}

@Suite struct PresetTests {
    @Test func presetsCapOnlyWhereTheBackendCan() throws {
        let core = CellarCore(paths: CellarPaths(root: try tempDir()))
        var game = GameProfile(appId: "1")
        game.graphics = .dxmt
        game.preset = .battery
        #expect(core.launchConfig(for: game).extraEnvironment["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=30;")
        game.frameCap = 0
        #expect(core.launchConfig(for: game).extraEnvironment["DXMT_CONFIG"] == nil)
        #expect(core.launchConfig(for: game, preset: .balanced).extraEnvironment["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=60;")
        game.graphics = .d3dmetal
        game.frameCap = nil
        #expect(core.launchConfig(for: game).extraEnvironment["DXMT_CONFIG"] == nil)
    }

    @Test func retinaChangesTheSettingsFingerprint() throws {
        let core = CellarCore(paths: CellarPaths(root: try tempDir()))
        var game = GameProfile(appId: "1")
        let engine = URL(fileURLWithPath: "/e")
        let plain = core.fingerprint(core.launchConfig(for: game), engine: engine)
        game.retina = true
        #expect(core.fingerprint(core.launchConfig(for: game), engine: engine) != plain)
    }

    @Test func steamOverlayStaysOffUnlessAsked() throws {
        let core = CellarCore(paths: CellarPaths(root: try tempDir()))
        var game = GameProfile(appId: "1")
        let wine = core.steamBottle.wine(engine: URL(fileURLWithPath: "/e"))
        #expect(wine.environment(core.launchConfig(for: game))["WINEDLLOVERRIDES"]?.contains("gameoverlayrenderer,gameoverlayrenderer64=;") == true)
        game.steamOverlay = true
        #expect(wine.environment(core.launchConfig(for: game))["WINEDLLOVERRIDES"]?.contains("gameoverlayrenderer,gameoverlayrenderer64=n,b") == true)
    }
}

@Suite struct RegistryTests {
    @Test func rendersRegedit5UTF16() throws {
        let data = RegistryFile.render([
            .dll("steam.exe", "winecoreaudio.drv", "disabled"),
            RegistryValue(key: #"HKEY_CURRENT_USER\X"#, name: "N", value: .dword(255)),
            RegistryValue(key: #"HKEY_CURRENT_USER\X"#, name: "Q", value: .string(#"a"b\c"#)),
        ])
        #expect(data.prefix(2) == Data([0xFF, 0xFE]))
        let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)!
        #expect(text.hasPrefix("Windows Registry Editor Version 5.00\r\n"))
        #expect(text.contains(#"[HKEY_CURRENT_USER\Software\Wine\AppDefaults\steam.exe\DllOverrides]"#))
        #expect(text.contains("\"N\"=dword:000000ff"))
        #expect(text.contains(#""Q"="a\"b\\c""#))
    }
}

@Suite struct ProfileTests {
    @Test func overridesWinFieldByField() throws {
        let root = try tempDir()
        let store = ProfileStore(paths: CellarPaths(root: root))
        try FileManager.default.createDirectory(at: store.builtInDir, withIntermediateDirectories: true)
        try #"{"appId":"730","graphics":"dxmt","env":{"A":"1","B":"2"},"minRAMGB":8}"#
            .write(to: store.builtInDir.appending(path: "730.json"), atomically: true, encoding: .utf8)
        var mine = GameProfile(appId: "730")
        mine.env = ["B": "3"]
        try store.saveOverride(mine)

        let p = store.profile(for: "730")
        #expect(p.backend == .dxmt)
        #expect(p.env == ["A": "1", "B": "3"])
        #expect(p.minRAMGB == 8)
        #expect(store.profile(for: "1").backend == .d3dmetal)
    }

    @Test func shippedProfilesDecode() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../profiles", directoryHint: .isDirectory).standardizedFileURL
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            let profile = try JSONDecoder().decode(GameProfile.self, from: Data(contentsOf: file))
            #expect(file.deletingPathExtension().lastPathComponent == profile.appId)
        }
    }
}

@Suite struct EnvironmentTests {
    let paths = CellarPaths(root: URL(fileURLWithPath: "/tmp/cellar-env"))

    @Test func backendsWireTheirDLLs() {
        let wine = Wine(paths: paths, engine: URL(fileURLWithPath: "/e"), bottle: URL(fileURLWithPath: "/b"))
        let d3d = wine.environment(LaunchConfig(backend: .d3dmetal))
        #expect(d3d["WINEPREFIX"] == "/b")
        #expect(d3d["WINEMSYNC"] == "1")
        #expect(d3d["CX_APPLEGPTK_LIBD3DSHARED_PATH"]?.hasSuffix("libd3dshared.dylib") == true)
        #expect(d3d["WINEDLLOVERRIDES"]?.contains("dxgi,d3d11,d3d12,d3d10,atidxx64=b") == true)

        let dxmt = wine.environment(LaunchConfig(backend: .dxmt, extraEnvironment: ["X": "1", "WINEMSYNC": ""]))
        #expect(dxmt["WINEDLLOVERRIDES"]?.contains("d3d12,nvapi64,nvngx=") == true)
        #expect(dxmt["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == nil)
        #expect(dxmt["X"] == "1")
        #expect(dxmt["WINEMSYNC"] == nil)
    }

    @Test func windowsPaths() {
        let wine = Wine(paths: paths, engine: URL(fileURLWithPath: "/e"), bottle: URL(fileURLWithPath: "/b"))
        #expect(wine.windowsPath(URL(fileURLWithPath: "/b/drive_c/cellar/SteamSetup.exe")) == #"C:\cellar\SteamSetup.exe"#)
        #expect(wine.windowsPath(URL(fileURLWithPath: "/Users/x/a.exe")) == #"Z:\Users\x\a.exe"#)
    }
}

@Suite struct PackTests {
    @Test func installsAndSwapsArchives() throws {
        let root = try tempDir()
        let paths = CellarPaths(root: root)
        try paths.ensureLayout()
        let src = root.appending(path: "src/v1/x86_64-windows", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "dll".write(to: src.appending(path: "d3d11.dll"), atomically: true, encoding: .utf8)
        let archive = root.appending(path: "dxmt.tar.gz")
        try Shell.check("/usr/bin/tar", ["-czf", archive.path, "-C", root.appending(path: "src").path, "v1"])
        let sha = try Downloader.sha256Hex(of: archive)

        let store = PackStore(paths: paths)
        let entry = PackEntry(kind: .dxmt, version: "1", url: archive, sha256: sha, archiveRoot: "v1")
        try store.installArchive(archive, entry: entry)
        #expect(FileManager.default.fileExists(atPath: paths.pack(.dxmt).appending(path: "x86_64-windows/d3d11.dll").path))
        #expect(store.isCurrent(entry))
        try store.installArchive(archive, entry: entry)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.packs.path).filter { $0.hasPrefix("old-") || $0.hasPrefix("staging-") }
        #expect(leftovers.isEmpty)
    }

    @Test func rejectsBadChecksums() async throws {
        let root = try tempDir()
        let file = root.appending(path: "a.bin")
        try Data("x".utf8).write(to: file)
        await #expect(throws: CellarError.self) {
            _ = try await Downloader(directory: root).fetch(file, sha256: String(repeating: "0", count: 64))
        }
    }
}

@Suite struct FriendsTests {
    @Test func parsesInGameProfile() {
        let p = FriendsService.parseProfile("""
        <profile><steamID><![CDATA[mate]]></steamID><onlineState>in-game</onlineState>
        <stateMessage><![CDATA[In-Game<br/>One More Lawn]]></stateMessage><privacyState>public</privacyState>
        <avatarMedium><![CDATA[https://avatars.example/a_medium.jpg]]></avatarMedium>
        <inGameInfo><gameName><![CDATA[One More Lawn]]></gameName></inGameInfo></profile>
        """)
        #expect(p.state == .inGame)
        #expect(p.game == "One More Lawn")
        #expect(p.name == "mate")
    }

    @Test func privateProfilesStayUnknown() {
        let p = FriendsService.parseProfile("<profile><steamID>x</steamID><onlineState>online</onlineState><privacyState>private</privacyState></profile>")
        #expect(p.state == .unknown)
    }

    @Test func joinLinksMatchSteamsOwnFormat() {
        var friend = SteamFriend(id: "765", name: "x", avatar: nil, state: .inGame, game: nil, statusText: nil,
                                 appID: "730", lobby: "109", connect: "+connect 1.2.3.4:27015")
        #expect(friend.joinLink == "steam://joinlobby/730/109/765")
        friend.lobby = "0"
        #expect(friend.joinLink == "steam://rungame/730/765/%2Bconnect%201.2.3.4%3A27015")
        friend.connect = ""
        #expect(friend.joinLink == nil)
        friend.lobby = "1;rm"
        #expect(friend.joinLink == nil)
    }

    @Test func snapshotBecomesFriends() throws {
        let json = #"{"ok":true,"me":"1","app":0,"lobby":"0","connect":"","friends":[{"id":"2","name":"b","state":1},{"id":"3","name":"a","state":1,"app":730,"lobby":"9","connect":""},{"id":"4","name":"c","state":0}]}"#
        let snapshot = try JSONDecoder().decode(BridgeSnapshot.self, from: Data(json.utf8))
        let service = FriendsService(steam: Steam(bottle: Bottle(paths: CellarPaths(root: try tempDir()), name: "steam")))
        let list = service.friends(from: snapshot, gameNames: ["730": "CS2"])
        #expect(list.map(\.id) == ["3", "2", "4"])
        #expect(list[0].game == "CS2")
        #expect(list[0].joinLink == "steam://joinlobby/730/9/3")
        #expect(list[2].state == .offline)
    }

    @Test func steamLinksGoToWindowsSteam() {
        #expect(Steam.arguments(.url("steam://friends/message/1")).last == "steam://friends/message/1")
    }
}

@Suite struct OfflineModeTests {
    @Test func togglesSteamOfflineSetting() throws {
        let root = try tempDir()
        let steam = Steam(bottle: Bottle(paths: CellarPaths(root: root), name: "steam"))
        try FileManager.default.createDirectory(at: steam.loginUsersURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        "users"
        {
        \t"76561199377149677"
        \t{
        \t\t"AccountName"\t\t"me"
        \t\t"RememberPassword"\t\t"1"
        \t\t"MostRecent"\t\t"1"
        \t}
        }
        """.write(to: steam.loginUsersURL, atomically: true, encoding: .utf8)
        #expect(!steam.offlineMode)
        try steam.setOfflineMode(true)
        #expect(steam.offlineMode)
        try steam.setOfflineMode(false)
        #expect(!steam.offlineMode)
        #expect(try VDF.parse(contentsOf: steam.loginUsersURL)["users"]?["76561199377149677"]?["SkipOfflineModeWarning"]?.string == "0")
    }
}

@Suite struct ConnectionTests {
    @Test func automaticFollowsTheNetwork() {
        #expect(ConnectionMode.automatic.wantsOffline(.reachable) == false)
        #expect(ConnectionMode.automatic.wantsOffline(.blocked) == true)
        #expect(ConnectionMode.automatic.wantsOffline(.noInternet) == true)
        #expect(ConnectionMode.online.wantsOffline(.blocked) == false)
        #expect(ConnectionMode.offline.wantsOffline(.reachable) == true)
    }

    @Test func directoryPrefersPort443AndOnlyWebSockets() {
        let json = #"{"response":{"serverlist":[{"endpoint":"a:27018","type":"websockets"},{"endpoint":"b:443","type":"websockets"},{"endpoint":"c:27017","type":"netfilter"}]}}"#
        #expect(SteamConnectivity.connectionServers(fromDirectory: Data(json.utf8)) == ["b:443", "a:27018"])
        #expect(SteamConnectivity.connectionServers(fromDirectory: Data("nope".utf8)) == [])
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    @Test func readsSignInFromSteamsLog() {
        let attempts = """
        [2026-11-02 02:11:53] [Connecting, 4, 0] [U:1:1] PingWebSocketCM() (cmp2-syd1.steamserver.net:443) starting...
        [2026-11-02 02:11:54] [Connecting, 4, 7] [U:1:1] Connect() starting connection (eNetQOSLevelHigh, x, WebSocket)
        """
        let start = date("2026-11-02 02:11:00")
        #expect(Steam.logonState(log: attempts, since: start) == .tryingSince(date("2026-11-02 02:11:53")))
        let connected = attempts + "\n[2026-11-02 02:11:54] [Connecting, 4, 7] [U:1:1] ConnectionCompleted() (1.2.3.4:27018, WebSocket) local"
        #expect(Steam.logonState(log: connected, since: start) == .connected)
        let on = connected + "\n[2026-11-02 02:11:54] [Logged On, 4, 7] [U:1:1] RecvMsgClientLogOnResponse() : processing complete"
        #expect(Steam.logonState(log: on, since: start) == .loggedOn)
        let off = on + "\n[2026-11-02 02:16:23] [Logged On, 4, 7] [U:1:1] LogOff()\n[2026-11-02 02:16:23] [Logged Off, 0, 0] [U:1:1] ConnectionDisconnected()"
        #expect(Steam.logonState(log: off, since: start) == .idle)
    }

    @Test func handlesWindowsLineEndings() {
        let log = "[2026-11-02 02:40:28] [Connecting, 4, 7] [U:1:1] Connect() starting connection\r\n[2026-11-02 02:40:29] [Logged On, 4, 7] [U:1:1] RecvMsgClientLogOnResponse() : processing complete\r\n[2026-11-02 02:40:29] CClientJobGetClientUpdateHosts: cached version not expired\r\n"
        #expect(Steam.logonState(log: log, since: date("2026-11-02 02:40:00")) == .loggedOn)
    }

    @Test func ignoresEarlierSessionsInTheLog() {
        let log = "[2026-11-02 02:11:54] [Logged On, 4, 7] [U:1:1] RecvMsgClientLogOnResponse() : processing complete"
        #expect(Steam.logonState(log: log, since: date("2026-11-02 03:00:00")) == .idle)
    }
}

@Suite struct CompatibilityTests {
    @Test func kernelAntiCheatIsBlockedUnlessProvenHere() {
        var facts = CompatibilityFacts()
        facts.antiCheatFiles = ["BattlEye"]
        #expect(CompatibilityAssessor.assess(facts, memoryGB: 16).verdict == .blocked)
        facts.antiCheatStatus = "Supported"
        #expect(CompatibilityAssessor.assess(facts, memoryGB: 16).verdict == .mayStruggle)
        facts.antiCheatStatus = "Denied"
        facts.playedSeconds = 3600
        #expect(CompatibilityAssessor.assess(facts, memoryGB: 16).verdict == .runsWell)
    }

    @Test func vacIsFine() {
        var facts = CompatibilityFacts()
        facts.antiCheats = ["VAC"]
        facts.antiCheatStatus = "Supported"
        facts.protonTier = "gold"
        #expect(CompatibilityAssessor.assess(facts, memoryGB: 16).verdict == .shouldRun)
    }

    @Test func memoryDependsOnThisMac() {
        var facts = CompatibilityFacts()
        facts.minimumMemoryGB = 16
        facts.protonTier = "platinum"
        #expect(CompatibilityAssessor.assess(facts, memoryGB: 8).verdict == .mayStruggle)
        #expect(CompatibilityAssessor.assess(facts, memoryGB: 24).verdict == .shouldRun)
    }

    @Test func playersOwnWordWins() {
        var facts = CompatibilityFacts()
        facts.antiCheatFiles = ["BattlEye"]
        facts.report = true
        #expect(CompatibilityAssessor.assess(facts, memoryGB: 16).verdict == .runsWell)
        facts = CompatibilityFacts()
        facts.playedSeconds = 7200
        facts.report = false
        #expect(CompatibilityAssessor.assess(facts, memoryGB: 16).verdict == .mayStruggle)
    }

    @Test func quickExitsCount() {
        var stats = CellarState.GameStats()
        stats.record(sessionSeconds: 5)
        stats.record(sessionSeconds: 8)
        #expect(stats.quickExits == 2)
        var facts = CompatibilityFacts()
        facts.quickExits = stats.quickExits
        #expect(CompatibilityAssessor.assess(facts, memoryGB: 16).verdict == .mayStruggle)
        stats.record(sessionSeconds: 1200)
        #expect(stats.quickExits == 0)
        #expect(stats.playedSeconds == 1200)
    }

    @Test func nothingKnownSaysSo() {
        #expect(CompatibilityAssessor.assess(CompatibilityFacts(), memoryGB: 16).verdict == .unknown)
    }

    @Test func readsMemoryFromRequirements() {
        #expect(CompatibilityAssessor.minimumMemoryGB(requirements: "<ul><li><strong>Memory:</strong> 8 GB RAM<br></li></ul>") == 8)
        #expect(CompatibilityAssessor.minimumMemoryGB(requirements: "<strong>Memory:</strong> 512 MB RAM") == 1)
        #expect(CompatibilityAssessor.minimumMemoryGB(requirements: "<strong>Storage:</strong> 8 GB available") == nil)
    }

    /// The smallest 64-bit program header with an import table naming d3d12.dll.
    private func samplePE() -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        func put32(_ value: Int, at: Int) { for i in 0..<4 { bytes[at + i] = UInt8((value >> (8 * i)) & 0xFF) } }
        func put16(_ value: Int, at: Int) { for i in 0..<2 { bytes[at + i] = UInt8((value >> (8 * i)) & 0xFF) } }
        put16(0x5A4D, at: 0)
        put32(0x80, at: 0x3C)
        put32(0x4550, at: 0x80)
        put16(1, at: 0x86)        // one section
        put16(240, at: 0x94)      // optional header size
        put16(0x20B, at: 0x98)    // 64-bit
        put32(0x1000, at: 0x98 + 112 + 8)   // import table address
        let section = 0x98 + 240
        put32(0x1000, at: section + 8)
        put32(0x1000, at: section + 12)
        put32(0x200, at: section + 16)
        put32(0x200, at: section + 20)
        put32(0x1100, at: 0x200 + 12)       // first import's name
        for (i, c) in "d3d12.dll".utf8.enumerated() { bytes[0x300 + i] = c }
        return Data(bytes)
    }

    @Test func readsImportsFromAProgram() throws {
        let pe = try #require(PEFile(data: samplePE()))
        #expect(pe.is64Bit)
        #expect(pe.imports == ["d3d12.dll"])
        #expect(PEFile(data: Data("not a program".utf8)) == nil)
    }

    @Test func scanFindsAntiCheatAndGraphics() throws {
        let folder = try tempDir()
        try FileManager.default.createDirectory(at: folder.appending(path: "EasyAntiCheat"), withIntermediateDirectories: true)
        try samplePE().write(to: folder.appending(path: "Game.exe"))
        let result = CompatibilityAssessor.scan(folder: folder)
        #expect(result.antiCheat == ["Easy Anti-Cheat"])
        #expect(result.graphicsAPIs == ["d3d12"])
        #expect(result.is32Bit == false)
    }
}

@Suite struct ClipTests {
    private func frames(_ seconds: Int) -> [ClipTimeline.Frame] {
        (0..<(seconds * 10)).map { ClipTimeline.Frame(time: Double($0) / 10, isKeyframe: $0 % 10 == 0) }
    }

    @Test func startsOnTheKeyframeBeforeTheWantedTime() throws {
        let all = frames(40)
        let span = try #require(ClipTimeline.span(of: all, seconds: 30))
        #expect(all[span.lowerBound].isKeyframe)
        #expect(all[span.lowerBound].time <= all.last!.time - 30)
        #expect(all[span.lowerBound].time > all.last!.time - 31)
        #expect(span.upperBound == all.count)
    }

    @Test func aShortRecordingSavesWhatItHas() throws {
        let all = frames(5)
        #expect(try #require(ClipTimeline.span(of: all, seconds: 30)).lowerBound == 0)
        #expect(ClipTimeline.span(of: [], seconds: 30) == nil)
        #expect(ClipTimeline.span(of: [.init(time: 1, isKeyframe: false)], seconds: 30) == nil)
    }

    @Test func outputSizeIsEvenAndCapped() {
        #expect(ClipRecorder.outputSize(width: 3456, height: 2234, maxHeight: 1080) == (1670, 1080))
        #expect(ClipRecorder.outputSize(width: 1281, height: 721, maxHeight: 1080) == (1280, 720))
    }

    @Test func listsClipsNewestFirstWithSafeNames() throws {
        let root = try tempDir()
        #expect(ClipLibrary.newURL(game: "A/B: C", kind: .video).deletingLastPathComponent().lastPathComponent == "A-B- C")
        let folder = root.appending(path: "Teardown")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "one.mp4"))
        try Data().write(to: folder.appending(path: "two.png"))
        try Data().write(to: folder.appending(path: "skip.txt"))
        let items = ClipLibrary.items(root: root)
        #expect(items.count == 2)
        #expect(Set(items.map(\.kind)) == [.video, .screenshot])
        #expect(ClipLibrary.items(game: "Teardown", root: root).count == 2)
        #expect(ClipLibrary.items(game: "Other", root: root).isEmpty)
    }
}

@Suite struct SpotifyTests {
    @Test func readsTheNotification() {
        let state = SpotifyState(notification: ["Player State": "Playing", "Track ID": "spotify:track:1", "Name": "Song", "Artist": "Band",
                                                "Album": "Record", "Duration": NSNumber(value: 200_000), "Playback Position": NSNumber(value: 12.5)])
        #expect(state.isPlaying)
        #expect(state.name == "Song")
        #expect(state.duration == 200)
        #expect(state.position == 12.5)
        #expect(!SpotifyState(notification: ["Player State": "Paused"]).isPlaying)
        #expect(!SpotifyState(notification: [:]).hasTrack)
    }

    @Test func readsTheScriptsAnswer() {
        let sep = "\u{1F}"
        let state = SpotifyPlayer.parse(["playing", "70", "12,5", "spotify:track:1", "Song", "Band", "Record", "200000", "https://i.scdn.co/image/a"].joined(separator: sep) + "\n")
        #expect(state.isPlaying)
        #expect(state.volume == 70)
        #expect(state.position == 12.5)
        #expect(state.duration == 200)
        #expect(state.artwork?.host() == "i.scdn.co")
        let stopped = SpotifyPlayer.parse("stopped" + sep + "40")
        #expect(!stopped.isPlaying)
        #expect(stopped.volume == 40)
        #expect(!stopped.hasTrack)
    }

    @Test func commandsStayInRange() {
        #expect(SpotifyPlayer.Command.volume(140).script == "set sound volume to 100")
        #expect(SpotifyPlayer.Command.seek(-3).script == "set player position to 0.0")
    }
}

@Suite struct BackendFallbackTests {
    @Test func triesEachOptionThatSuitsTheGame() {
        #expect(BackendFallback.next(tried: [.d3dmetal], apis: ["d3d11"], is32Bit: false) == .dxmt)
        #expect(BackendFallback.next(tried: [.d3dmetal, .dxmt], apis: ["d3d11"], is32Bit: false) == .wined3d)
        #expect(BackendFallback.next(tried: [.d3dmetal, .dxmt, .wined3d], apis: ["d3d11"], is32Bit: false) == nil)
    }

    @Test func respectsWhatEachOptionCanDo() {
        #expect(BackendFallback.next(tried: [.d3dmetal], apis: ["d3d12"], is32Bit: false) == nil)
        #expect(BackendFallback.next(tried: [.d3dmetal], apis: ["d3d11", "d3d12"], is32Bit: false) == .dxmt)
        #expect(BackendFallback.next(tried: [.d3dmetal], apis: ["d3d11"], is32Bit: true) == .wined3d)
        // Unity links to DirectX 9 or OpenGL, then loads DirectX 11 while running.
        #expect(BackendFallback.next(tried: [.d3dmetal], apis: ["opengl32", "d3d9"], is32Bit: false) == .dxmt)
        #expect(BackendFallback.next(tried: [.d3dmetal], apis: [], is32Bit: nil) == .dxmt)
    }
}

@Suite struct ClipEditorTests {
    @Test func namesTrimmedCopiesWithoutOverwriting() throws {
        let dir = try tempDir()
        let source = dir.appending(path: "Game.mp4")
        #expect(ClipEditor.trimmedURL(for: source).lastPathComponent == "Game trimmed.mp4")
        try Data().write(to: dir.appending(path: "Game trimmed.mp4"))
        #expect(ClipEditor.trimmedURL(for: source).lastPathComponent == "Game trimmed 2.mp4")
    }

    @Test func refusesAnEmptyRange() async throws {
        let dir = try tempDir()
        await #expect(throws: CellarError.self) {
            try await ClipEditor.trim(dir.appending(path: "a.mp4"), from: 5, to: 5, saveTo: dir.appending(path: "b.mp4"))
        }
    }
}
