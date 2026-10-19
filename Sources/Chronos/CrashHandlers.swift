import ChronosCore
import Darwin
import Foundation

/// Signals that end the process: crashes, plus SIGTERM, which is how launchd and `kill` ask it to stop.
private let fatalSignals = [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGTERM]

/// On a crash, closes the open slot with the crash's time, then lets the signal do what it would have: macOS still
/// writes its crash report. Whatever this misses, the next launch closes.
func installCrashHandlers() {
    for signal in fatalSignals {
        Darwin.signal(signal, crashed)
    }
    NSSetUncaughtExceptionHandler { _ in CrashClose.run() }
}

private func crashed(_ signal: Int32) {
    // Never hang a crash: if closing the slot takes longer than this, SIGALRM ends the process.
    alarm(2)
    CrashClose.run()
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}
