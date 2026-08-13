import AppKit

let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
        Umbra — blacks out the physical screens while a remote session keeps seeing the desktop.

          (no options)     run the menu bar app
          --selftest       check displays, DDC and a full gamma cycle, then exit
          --selftest-ddc   the above plus a DDC backlight cycle
          --help           this message
        """)
    exit(0)
}

if arguments.contains("--selftest") || arguments.contains("--selftest-ddc") {
    exit(SelfTest.run(includeDDCCycle: arguments.contains("--selftest-ddc")))
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
