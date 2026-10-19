import ChronosCore
import Testing

struct ForegroundJobTests {
    /// `KERN_PROCARGS2`'s layout: the argument count, the executable's path, padding, then the arguments.
    private func processArguments(path: String, _ arguments: String...) -> [UInt8] {
        var bytes = withUnsafeBytes(of: Int32(arguments.count)) { Array($0) }
        bytes += Array(path.utf8) + [0, 0, 0, 0]
        for argument in arguments { bytes += Array(argument.utf8) + [0] }
        return bytes
    }

    @Test func usesTheNameItWasStartedAsNotItsFile() {
        let arguments = processArguments(path: "/Users/me/.local/share/claude/versions/2.1.303", "claude", "--resume")

        #expect(ForegroundJob.launchName(fromProcessArguments: arguments) == "claude")
    }

    @Test func dropsTheFolderAndALoginShellsDash() {
        #expect(ForegroundJob.launchName(fromProcessArguments: processArguments(path: "/bin/zsh", "-zsh")) == "zsh")
        #expect(
            ForegroundJob.launchName(
                fromProcessArguments: processArguments(path: "/usr/bin/vim", "/usr/bin/vim", "a.txt")
            )
                == "vim"
        )
    }

    @Test func nothingWithoutArguments() {
        #expect(ForegroundJob.launchName(fromProcessArguments: processArguments(path: "/bin/zsh")) == nil)
        #expect(ForegroundJob.launchName(fromProcessArguments: []) == nil)
    }

    @Test func nothingForADeviceThatIsNotThere() {
        #expect(ForegroundJob.leader(onTTY: "/dev/ttys-not-there") == nil)
    }
}
