import AppKit
import Testing
@testable import WinBar

/// Serves canned responses for GitHub and the update download; nothing leaves the machine.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (status: Int, body: Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { ["api.github.com", "updates.test"].contains(request.url?.host) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url, let r = Self.routes[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: r.status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

extension Desktop {
    @MainActor @Suite struct UpdaterTests {
        let latest = "https://api.github.com/repos/omega123456/WinBar/releases/latest"
        let download = "https://updates.test/WinBar.zip"

        func release(_ tag: String) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "tag_name": tag,
                "assets": [["name": "WinBar.dmg", "browser_download_url": "https://updates.test/WinBar.dmg"],
                           ["name": "WinBar.zip", "browser_download_url": download]],
            ])
        }

        /// A WinBar.app bundle (Info.plist only) with `version`.
        func bundle(_ version: String, at url: URL) {
            let contents = url.appendingPathComponent("Contents")
            try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: NSDictionary = ["CFBundleShortVersionString": version, "CFBundleIdentifier": "local.winbar"]
            plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        }

        func zip(_ version: String, in dir: URL) -> Data {
            let root = dir.appendingPathComponent("zip-\(version)-\(UUID().uuidString)")
            bundle(version, at: root.appendingPathComponent("WinBar.app"))
            let out = root.appendingPathComponent("update.zip")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--keepParent", root.appendingPathComponent("WinBar.app").path, out.path]
            try! ditto.run()
            ditto.waitUntilExit()
            return try! Data(contentsOf: out)
        }

        func installedVersion() -> String? {
            NSDictionary(contentsOf: Updater.bundleURL.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        }

        @Test func checksDownloadsVerifiesAndInstalls() async {
            let h = Harness()
            URLProtocol.registerClass(StubURLProtocol.self)
            defer { URLProtocol.unregisterClass(StubURLProtocol.self) }

            // Not an installed app: a manual check explains why, an automatic one is silent.
            Updater.check(manual: true)
            Updater.check(manual: false)
            #expect(h.notices == ["Updates unavailable"])
            Updater.isInstallable = true

            // GitHub fails; a second check while one runs is ignored.
            StubURLProtocol.routes = [latest: (500, Data())]
            Updater.check(manual: true)
            Updater.check(manual: true)
            await settle(0.5)
            #expect(h.notices.last == "Couldn't check for updates")
            Updater.check(manual: false)
            await settle(0.5)

            // Up to date (no newer version).
            StubURLProtocol.routes = [latest: (200, release("v0"))]
            Updater.check(manual: true)
            await settle(0.5)
            #expect(h.notices.last == "WinBar is up to date")
            Updater.check(manual: false)
            await settle(0.5)
            #expect(h.notices.count == 3)

            // Newer and accepted: downloaded, unpacked, verified, swapped in, relaunched.
            bundle("1.0", at: Updater.bundleURL)
            StubURLProtocol.routes = [latest: (200, release("v9.9.9")), download: (200, zip("9.9.9", in: h.dir))]
            var asked: [String] = []
            var relaunched: URL?
            Updater.ask = { version, onUpdate in asked.append(version); onUpdate() }
            Updater.relaunch = { relaunched = $0 }
            Updater.check(manual: false)
            await settle(1.5)
            #expect(asked == ["9.9.9"])
            #expect(relaunched == Updater.bundleURL)
            #expect(installedVersion() == "9.9.9")

            // Failures each end in a notice: wrong version inside, not a zip, download error, bad signature, swap error.
            func failedUpdate(_ tag: String, _ body: Data?) async {
                StubURLProtocol.routes = [latest: (200, release(tag))]
                if let body { StubURLProtocol.routes[download] = (200, body) }
                let before = h.notices.count
                Updater.check(manual: false)
                await settle(1.5)
                #expect(h.notices.count == before + 1)
                #expect(h.notices.last == "WinBar update failed")
            }
            await failedUpdate("v10", zip("9.9.9", in: h.dir))
            await failedUpdate("v10", Data("not a zip".utf8))
            await failedUpdate("v10", nil)
            Updater.verify = Updater.verifySignature // this test runner is not signed by WinBar Local Signing
            await failedUpdate("v10", zip("10", in: h.dir))
            Updater.verify = { _ in }
            Updater.relaunch = { _ in throw CocoaError(.fileWriteUnknown) }
            await failedUpdate("v10", zip("10", in: h.dir))
            #expect(h.log.contains("update install failed"))

            // Automatic updates: checked at start and hourly; the menu toggle turns them off and on.
            StubURLProtocol.routes = [latest: (200, release("v0"))]
            #expect(Updater.isEnabled)
            Updater.start()
            Updater.start()
            await settle(0.5)
            Updater.toggle()
            #expect(!Updater.isEnabled)
            Updater.start()
            Updater.toggle()
            #expect(Updater.isEnabled)
            await settle(0.5)
            Updater.toggle()
            Updater.toggle()
            Updater.toggle()
            #expect(!Updater.isEnabled)
            Updater.isInstallable = false
        }
    }
}
