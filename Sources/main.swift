import Cocoa
import InputMethodKit
import Carbon

// Held for the lifetime of the process. The IMKServer owns the Mach connection
// that host apps talk to; IMKCandidates is the shared candidate window.
var sharedServer: IMKServer!
var sharedCandidates: IMKCandidates!

// Custom NSApplication subclass so we can install a delegate without a
// MainMenu.nib. The Swift module-qualified name (RomKana.NSManualApplication)
// is referenced from Info.plist via NSPrincipalClass.
final class NSManualApplication: NSApplication {
    private let appDelegate = AppDelegate()
    override init() {
        super.init()
        self.delegate = appDelegate
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }
}

func launchMark(_ s: String) {
    let line = s + "\n"
    let path = "/tmp/romkana_launch.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); fh.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        launchMark("didFinishLaunching")
        // The connection name MUST match Info.plist InputMethodConnectionName,
        // so read it from the bundle rather than hard-coding it twice.
        let connectionName =
            Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String
        launchMark("connectionName=\(connectionName ?? "nil") bundleId=\(Bundle.main.bundleIdentifier ?? "nil")")
        sharedServer = IMKServer(name: connectionName,
                                 bundleIdentifier: Bundle.main.bundleIdentifier)
        launchMark("IMKServer created = \(sharedServer != nil)")
        sharedCandidates = IMKCandidates(server: sharedServer,
                                         panelType: kIMKSingleColumnScrollingCandidatePanel)
        launchMark("IMKCandidates created = \(sharedCandidates != nil)")
        dumpInputSources()
        let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        launchMark("TISRegisterInputSource status=\(status)")
        dumpInputSources()
        Log.info("RomKana started. connection=\(connectionName ?? "nil")")
    }

    private func dumpInputSources() {
        guard let cf = TISCreateInputSourceList(nil, true)?.takeRetainedValue() else {
            launchMark("TIS list = nil"); return
        }
        let arr = cf as! [TISInputSource]
        var mine: [String] = []
        for s in arr {
            guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
            if id.lowercased().contains("romkana") || id.lowercased().contains("toshinao") {
                mine.append(id)
            }
        }
        launchMark("TIS total=\(arr.count) romkana=\(mine)")
    }
}

let app = NSManualApplication.shared
app.run()
