const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;

pub const Timeval = struct {
    tv_sec: i64,
    tv_usec: i32,
};

pub const MemInfo = struct {
    mem_total: u64, // in KB
    mem_free: u64,
    mem_available: u64,
    buffers: u64,
    cached: u64,
    swap_total: u64,
    swap_free: u64,
    sreclaimable: u64,
    shmem: u64,
};

pub const CpuInfo = struct {
    model_name: ?[]const u8,
    vendor_id: ?[]const u8,
    cpu_cores: ?u32,
    cpu_mhz: ?f64,
};

pub const ProcessInfo = struct {
    pid: i32,
    ppid: i32,
    name: []const u8,
};

/// Read a file from /proc or /sys filesystem
pub fn readProcFile(allocator: Allocator, path: []const u8) ![]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    return try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
}

/// Read a single line from a file (for /sys files that contain single values)
pub fn readSysFile(allocator: Allocator, path: []const u8) ![]u8 {
    const content = try readProcFile(allocator, path);
    defer allocator.free(content);

    // Trim whitespace and return
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

/// Parse /proc/meminfo and return memory statistics
pub fn parseProcMeminfo(allocator: Allocator) !MemInfo {
    const content = try readProcFile(allocator, "/proc/meminfo");
    defer allocator.free(content);

    var result = MemInfo{
        .mem_total = 0,
        .mem_free = 0,
        .mem_available = 0,
        .buffers = 0,
        .cached = 0,
        .swap_total = 0,
        .swap_free = 0,
        .sreclaimable = 0,
        .shmem = 0,
    };

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Parse "Key: Value kB" format
        var parts = std.mem.splitSequence(u8, line, ":");
        const key = parts.next() orelse continue;
        const value_str = parts.next() orelse continue;

        const trimmed = std.mem.trim(u8, value_str, " \t");
        var value_parts = std.mem.splitScalar(u8, trimmed, ' ');
        const num_str = value_parts.next() orelse continue;
        const value = std.fmt.parseInt(u64, num_str, 10) catch continue;

        if (std.mem.eql(u8, key, "MemTotal")) {
            result.mem_total = value;
        } else if (std.mem.eql(u8, key, "MemFree")) {
            result.mem_free = value;
        } else if (std.mem.eql(u8, key, "MemAvailable")) {
            result.mem_available = value;
        } else if (std.mem.eql(u8, key, "Buffers")) {
            result.buffers = value;
        } else if (std.mem.eql(u8, key, "Cached")) {
            result.cached = value;
        } else if (std.mem.eql(u8, key, "SwapTotal")) {
            result.swap_total = value;
        } else if (std.mem.eql(u8, key, "SwapFree")) {
            result.swap_free = value;
        } else if (std.mem.eql(u8, key, "SReclaimable")) {
            result.sreclaimable = value;
        } else if (std.mem.eql(u8, key, "Shmem")) {
            result.shmem = value;
        }
    }

    return result;
}

/// Parse /proc/cpuinfo and return CPU information
pub fn parseProcCpuinfo(allocator: Allocator) !CpuInfo {
    const content = try readProcFile(allocator, "/proc/cpuinfo");
    defer allocator.free(content);

    var result = CpuInfo{
        .model_name = null,
        .vendor_id = null,
        .cpu_cores = null,
        .cpu_mhz = null,
    };

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var parts = std.mem.splitSequence(u8, line, ":");
        const key = std.mem.trim(u8, parts.next() orelse continue, " \t");
        const value = std.mem.trim(u8, parts.next() orelse continue, " \t");

        if (std.mem.eql(u8, key, "model name") and result.model_name == null) {
            result.model_name = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "vendor_id") and result.vendor_id == null) {
            result.vendor_id = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "cpu cores") and result.cpu_cores == null) {
            result.cpu_cores = std.fmt.parseInt(u32, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "cpu MHz") and result.cpu_mhz == null) {
            result.cpu_mhz = std.fmt.parseFloat(f64, value) catch null;
        }
    }

    return result;
}

/// Parse /etc/os-release and return key-value pairs
pub fn parseOsRelease(allocator: Allocator) !std.StringHashMap([]const u8) {
    var result = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        result.deinit();
    }

    const content = readProcFile(allocator, "/etc/os-release") catch |err| {
        if (err == error.FileNotFound) {
            // Try fallback location
            const fallback = readProcFile(allocator, "/usr/lib/os-release") catch {
                return result;
            };
            defer allocator.free(fallback);
            try parseOsReleaseContent(allocator, fallback, &result);
            return result;
        }
        return err;
    };
    defer allocator.free(content);

    try parseOsReleaseContent(allocator, content, &result);
    return result;
}

fn parseOsReleaseContent(allocator: Allocator, content: []const u8, result: *std.StringHashMap([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq_pos];
        var value = line[eq_pos + 1 ..];

        // Remove quotes if present
        if (value.len >= 2 and (value[0] == '"' or value[0] == '\'')) {
            value = value[1 .. value.len - 1];
        }

        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        const value_copy = try allocator.dupe(u8, value);

        try result.put(key_copy, value_copy);
    }
}

/// Read uptime from /proc/uptime (returns seconds as float)
pub fn readUptime() !f64 {
    var buffer: [64]u8 = undefined;
    const file = try std.fs.openFileAbsolute("/proc/uptime", .{});
    defer file.close();

    const bytes_read = try file.read(&buffer);
    const content = buffer[0..bytes_read];

    // First number is uptime in seconds
    var parts = std.mem.splitScalar(u8, content, ' ');
    const uptime_str = parts.next() orelse return error.ParseError;

    return std.fmt.parseFloat(f64, uptime_str) catch error.ParseError;
}

/// Get process info by reading /proc/[pid]/stat
pub fn getProcessInfo(allocator: Allocator, pid: i32) !ProcessInfo {
    var path_buf: [64]u8 = undefined;

    // Read comm for process name
    const comm_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid});
    const name = readSysFile(allocator, comm_path) catch try allocator.dupe(u8, "unknown");
    errdefer allocator.free(name);

    // Read stat for ppid
    const stat_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid});
    const stat_content = try readProcFile(allocator, stat_path);
    defer allocator.free(stat_content);

    // Parse stat: pid (comm) state ppid ...
    // Find the closing paren to skip comm field (which may contain spaces)
    const paren_end = std.mem.lastIndexOfScalar(u8, stat_content, ')') orelse return error.ParseError;
    const after_comm = stat_content[paren_end + 2 ..]; // Skip ") "

    var fields = std.mem.splitScalar(u8, after_comm, ' ');
    _ = fields.next(); // state
    const ppid_str = fields.next() orelse return error.ParseError;
    const ppid = try std.fmt.parseInt(i32, ppid_str, 10);

    return ProcessInfo{
        .pid = pid,
        .ppid = ppid,
        .name = name,
    };
}

/// Get hostname from /proc/sys/kernel/hostname
pub fn getHostname(allocator: Allocator) ![]u8 {
    return readSysFile(allocator, "/proc/sys/kernel/hostname");
}

/// Get username from environment
pub fn getUsername(allocator: Allocator) ![]u8 {
    const user = std.process.getEnvVarOwned(allocator, "USER") catch {
        return try allocator.dupe(u8, "unknown");
    };
    return user;
}

/// Count lines matching a pattern in a file (for dpkg status)
pub fn countLinesMatching(allocator: Allocator, path: []const u8, pattern: []const u8) !u32 {
    const content = readProcFile(allocator, path) catch {
        return 0;
    };
    defer allocator.free(content);

    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, pattern) != null) {
            count += 1;
        }
    }

    return count;
}
