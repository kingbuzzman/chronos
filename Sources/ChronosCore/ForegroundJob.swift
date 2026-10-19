package import Darwin

/// The program a terminal tab is running: the leader of the job in front on the tab's terminal device. It's what the
/// shell launched, such as `claude` or `vim`, even while that program runs helpers of its own, and the shell itself when
/// nothing else is running. Read with system calls, without running `ps`.
package enum ForegroundJob {
    /// A job's leader. Its start time tells a reused process ID apart from the process that had it before.
    package struct Leader: Hashable, Sendable {
        package let pid: pid_t
        package let started: Int
    }

    /// The leader of the job in front on the terminal device at `tty`, such as `/dev/ttys012`. A few system calls.
    package static func leader(onTTY tty: String) -> Leader? {
        var info = stat()
        guard stat(tty, &info) == 0 else { return nil }
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(info.st_rdev)]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
        // Room for a few more, in case processes start between the two calls.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 8)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return nil }
        guard
            let leader = processes.prefix(size / MemoryLayout<kinfo_proc>.stride)
                .first(where: { $0.kp_proc.p_pid == $0.kp_eproc.e_tpgid })
        else { return nil }
        let started = leader.kp_proc.p_un.__p_starttime
        return Leader(pid: leader.kp_proc.p_pid, started: started.tv_sec * 1_000_000 + Int(started.tv_usec))
    }

    /// The name a program was started as, which for `claude` differs from its file, named after its version. Reads
    /// the process's arguments, up to a megabyte, so it's worth remembering per `Leader`.
    package static func launchName(of pid: pid_t) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return launchName(fromProcessArguments: Array(buffer.prefix(size)))
    }

    /// The last part of a process's first argument, without a login shell's leading dash, from `KERN_PROCARGS2`'s
    /// layout: the argument count, the executable's path, padding, then the arguments. Nothing after the first argument
    /// is read: the rest can hold paths, hosts or secrets.
    package static func launchName(fromProcessArguments buffer: [UInt8]) -> String? {
        var index = MemoryLayout<Int32>.size
        guard buffer.count > index else { return nil }
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        let start = index
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        var name = String(decoding: buffer[start..<index], as: UTF8.self)
        name = name.split(separator: "/").last.map(String.init) ?? ""
        if name.hasPrefix("-") { name.removeFirst() }
        return name.isEmpty ? nil : name
    }
}
