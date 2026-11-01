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
