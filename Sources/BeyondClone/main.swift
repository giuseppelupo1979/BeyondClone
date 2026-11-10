import SwiftUI

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
}

// Le descrizioni al passaggio del mouse compaiono dopo mezzo secondo, anche se nelle preferenze
// globali del Mac il ritardo è stato alzato (NSInitialToolTipDelay). Vale solo per questa app.
UserDefaults.standard.set(500, forKey: "NSInitialToolTipDelay")

BeyondCloneApp.main()
