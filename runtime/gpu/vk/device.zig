//! Vulkan backend of the GPU runtime core (§14.11, §11.2.3, §11.6.4, §11.7):
//! device selection, resident buffers with staged upload/download, submission
//! ordering, deferred destruction and the device trap record.
//!
//! The Vulkan loader is opened at run time; with no loader or no usable ICD,
//! `Device.init` returns `error.NoDevice` (`GpuError.no_device`).
//!
//! Ordering model: one queue and one timeline semaphore. Submission `n`
//! signals value `n`, so "all work up to `n` is done" is one counter read.
//! Every command buffer starts with a full memory barrier and ends with a
//! barrier to host reads, so commands execute in submission order (§11.6.4).

const std = @import("std");
const vk = @import("vk.zig");
const rt_trap = @import("../../trap.zig");

/// Runtime mirror of `GpuError` (§14.11) for the cases this layer produces.
pub const Error = error{ NoDevice, Unsupported, DeviceLost, OutOfMemory };

/// A trap site numbered by the compiler: the `site` word of a trap record
/// indexes the program-wide table of these.
pub const TrapSite = struct { msg: []const u8, file: []const u8, line: u32 };

/// Program-wide GPU trap site table. Compiled programs set it once at startup,
/// before the first `launch`; it is read only when a trap record is set.
pub var trap_sites: []const TrapSite = &.{};

/// Layout of the device trap record buffer (§11.7), bound to every dispatch.
/// A trapping invocation does `atomicCompareExchange(state, 0, 1)`; only the
/// winner stores `kind` (a `TrapKind` discriminant) and `site`.
pub const TrapRecord = extern struct { state: u32, kind: u32, site: u32 };

pub const Device = struct {
    gpa: std.mem.Allocator,
    lib: std.DynLib,
    ifns: vk.InstanceFns,
    fns: vk.DeviceFns,
    instance: vk.Instance,
    physical: vk.PhysicalDevice,
    handle: vk.Device,
    queue: vk.Queue,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    pool: vk.CommandPool,
    timeline: vk.Semaphore,
    /// Timeline value of the latest submission.
    submitted: u64 = 0,
    /// Timeline value known to be complete; never ahead of the device.
    completed: u64 = 0,
    lost: bool = false,
    trap_buffer: Allocation,
    /// Host-coherent, persistently mapped view of `trap_buffer`.
    trap_record: *TrapRecord,
    /// Resources released by their owner but still referenced by submitted
    /// work (§11.6.4 deferred destruction).
    garbage: std.ArrayList(Garbage) = .empty,

    const Garbage = struct { done_at: u64, res: Resource };
    const Resource = union(enum) { buffer: Allocation, commands: vk.CommandBuffer };

    /// Opens the first suitable adapter (§14.11 `Device.default`): the first
    /// Vulkan 1.2+ physical device with a compute queue. The returned device
    /// must not move while `Buffer`s created from it are alive.
    pub fn init(gpa: std.mem.Allocator) Error!Device {
        // shortcut: Linux loader name only; Windows/macOS names come with those targets.
        var lib = std.DynLib.open("libvulkan.so.1") catch return error.NoDevice;
        errdefer lib.close();
        const gipa = lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return error.NoDevice;
        const global = vk.load(vk.GlobalFns, null, gipa) orelse return error.NoDevice;

        const app: vk.ApplicationInfo = .{ .p_engine_name = "pyro", .api_version = vk.api_version_1_2 };
        var instance: vk.Instance = undefined;
        try initResult(global.vkCreateInstance(&.{ .p_application_info = &app }, null, &instance));
        const ifns = vk.load(vk.InstanceFns, instance, gipa) orelse return error.NoDevice;
        errdefer ifns.vkDestroyInstance(instance, null);

        const physical, const family = try pickPhysical(ifns, instance);

        const priority: f32 = 1;
        const queue_info: vk.DeviceQueueCreateInfo = .{ .queue_family_index = family, .queue_count = 1, .p_queue_priorities = (&priority)[0..1] };
        const timeline_features: vk.PhysicalDeviceTimelineSemaphoreFeatures = .{ .timeline_semaphore = 1 };
        var handle: vk.Device = undefined;
        try initResult(ifns.vkCreateDevice(physical, &.{
            .p_next = &timeline_features,
            .queue_create_info_count = 1,
            .p_queue_create_infos = (&queue_info)[0..1],
        }, null, &handle));
        const fns = vk.load(vk.DeviceFns, handle, ifns.vkGetDeviceProcAddr) orelse {
            // Cannot use `fns` to destroy the device it failed to load for.
            return error.Unsupported;
        };
        errdefer fns.vkDestroyDevice(handle, null);

        var queue: vk.Queue = undefined;
        fns.vkGetDeviceQueue(handle, family, 0, &queue);

        var pool: vk.CommandPool = .null;
        try initResult(fns.vkCreateCommandPool(handle, &.{
            .flags = vk.command_pool_create_transient_bit,
            .queue_family_index = family,
        }, null, &pool));
        errdefer fns.vkDestroyCommandPool(handle, pool, null);

        const timeline_info: vk.SemaphoreTypeCreateInfo = .{ .semaphore_type = vk.semaphore_type_timeline, .initial_value = 0 };
        var timeline: vk.Semaphore = .null;
        try initResult(fns.vkCreateSemaphore(handle, &.{ .p_next = &timeline_info }, null, &timeline));
        errdefer fns.vkDestroySemaphore(handle, timeline, null);

        var self: Device = .{
            .gpa = gpa,
            .lib = lib,
            .ifns = ifns,
            .fns = fns,
            .instance = instance,
            .physical = physical,
            .handle = handle,
            .queue = queue,
            .memory_properties = undefined,
            .pool = pool,
            .timeline = timeline,
            .trap_buffer = undefined,
            .trap_record = undefined,
        };
        ifns.vkGetPhysicalDeviceMemoryProperties(physical, &self.memory_properties);

        self.trap_buffer = try self.allocate(@sizeOf(TrapRecord), vk.buffer_usage_storage_buffer_bit | vk.buffer_usage_transfer_dst_bit, host_memory);
        errdefer self.free(self.trap_buffer);
        self.trap_record = @ptrCast(@alignCast(try self.map(self.trap_buffer)));
        self.trap_record.* = .{ .state = 0, .kind = 0, .site = 0 };
        return self;
    }

    /// Waits for all submitted work, then frees every device object. Not a
    /// completion point: a pending trap record is not re-raised.
    pub fn deinit(self: *Device) void {
        _ = self.fns.vkDeviceWaitIdle(self.handle);
        for (self.garbage.items) |g| self.destroy(g.res);
        self.garbage.deinit(self.gpa);
        self.free(self.trap_buffer);
        self.fns.vkDestroySemaphore(self.handle, self.timeline, null);
        self.fns.vkDestroyCommandPool(self.handle, self.pool, null);
        self.fns.vkDestroyDevice(self.handle, null);
        self.ifns.vkDestroyInstance(self.instance, null);
        self.lib.close();
        self.* = undefined;
    }

    /// Completion point (§11.6.4) that reports device loss.
    pub fn isLost(self: *Device) bool {
        self.waitIdle() catch {};
        return self.lost;
    }

    /// Completion point: waits for all submitted work and re-raises a GPU trap.
    pub fn waitIdle(self: *Device) Error!void {
        try self.complete(self.submitted);
    }

    /// Completion point for work up to timeline value `value`: waits, frees
    /// finished garbage, then turns a set trap record into a process trap.
    pub fn complete(self: *Device, value: u64) Error!void {
        try self.wait(value);
        self.checkTraps();
    }

    /// Traps the process (§9.4) if a GPU invocation set the trap record (§11.7).
    /// Call only when the work that may have set it is complete.
    pub fn checkTraps(self: *const Device) void {
        if (@atomicLoad(u32, &self.trap_record.state, .acquire) == 0) return;
        raiseGpuTrap(self.trap_record.kind, self.trap_record.site);
    }

    /// Starts a one-time command buffer for one submission.
    pub fn beginCommands(self: *Device) Error!vk.CommandBuffer {
        var cmd: [1]vk.CommandBuffer = undefined;
        try self.check(self.fns.vkAllocateCommandBuffers(self.handle, &.{ .command_pool = self.pool, .command_buffer_count = 1 }, &cmd));
        errdefer self.fns.vkFreeCommandBuffers(self.handle, self.pool, 1, &cmd);
        try self.check(self.fns.vkBeginCommandBuffer(cmd[0], &.{ .flags = vk.command_buffer_usage_one_time_submit_bit }));
        // shortcut: a full barrier serializes all submissions; finer barriers when dispatch overlap matters.
        self.barrier(cmd[0], vk.pipeline_stage_all_commands_bit, vk.access_memory_read_bit | vk.access_memory_write_bit);
        return cmd[0];
    }

    /// Ends and submits `cmd` from `beginCommands`, taking ownership of it, and
    /// returns its timeline value. Each buffer in `uses` stays alive on the
    /// device until that value completes, even if deinitialized earlier.
    pub fn submit(self: *Device, cmd: vk.CommandBuffer, uses: []const *Buffer) Error!u64 {
        errdefer self.fns.vkFreeCommandBuffers(self.handle, self.pool, 1, (&cmd)[0..1]);
        self.barrier(cmd, vk.pipeline_stage_host_bit, vk.access_host_read_bit);
        try self.check(self.fns.vkEndCommandBuffer(cmd));

        const value = self.submitted + 1;
        const timeline_info: vk.TimelineSemaphoreSubmitInfo = .{ .signal_semaphore_value_count = 1, .p_signal_semaphore_values = (&value)[0..1] };
        try self.check(self.fns.vkQueueSubmit(self.queue, 1, (&vk.SubmitInfo{
            .p_next = &timeline_info,
            .command_buffer_count = 1,
            .p_command_buffers = (&cmd)[0..1],
            .signal_semaphore_count = 1,
            .p_signal_semaphores = (&self.timeline)[0..1],
        })[0..1], .null));
        self.submitted = value;
        for (uses) |b| b.last_use = value;
        self.release(.{ .commands = cmd }, value);
        self.collect();
        return value;
    }

    /// Frees `res` once timeline value `done_at` completes (now, if it has).
    fn release(self: *Device, res: Resource, done_at: u64) void {
        if (done_at > self.completed) {
            if (self.garbage.append(self.gpa, .{ .done_at = done_at, .res = res })) return else |_| {
                // No room to defer: wait instead, which is slower but still safe.
                self.wait(done_at) catch {};
            }
        }
        self.destroy(res);
    }

    fn destroy(self: *Device, res: Resource) void {
        switch (res) {
            .buffer => |a| self.free(a),
            .commands => |c| self.fns.vkFreeCommandBuffers(self.handle, self.pool, 1, (&c)[0..1]),
        }
    }

    /// Waits for timeline value `value`, then frees finished garbage. On device
    /// loss nothing completes any more; `deinit` reclaims everything.
    fn wait(self: *Device, value: u64) Error!void {
        if (value > self.completed) {
            try self.check(self.fns.vkWaitSemaphores(self.handle, &.{
                .semaphore_count = 1,
                .p_semaphores = (&self.timeline)[0..1],
                .p_values = (&value)[0..1],
            }, std.math.maxInt(u64)));
        }
        self.collect();
    }

    /// Refreshes `completed` and frees the garbage it covers.
    fn collect(self: *Device) void {
        var value: u64 = 0;
        if (self.fns.vkGetSemaphoreCounterValue(self.handle, self.timeline, &value) != .success) return;
        self.completed = @max(self.completed, value);
        var i: usize = self.garbage.items.len;
        while (i > 0) {
            i -= 1;
            if (self.garbage.items[i].done_at <= self.completed) self.destroy(self.garbage.swapRemove(i).res);
        }
    }

    fn barrier(self: *Device, cmd: vk.CommandBuffer, dst_stage: u32, dst_access: u32) void {
        const mb: vk.MemoryBarrier = .{ .src_access_mask = vk.access_memory_write_bit, .dst_access_mask = dst_access };
        self.fns.vkCmdPipelineBarrier(cmd, vk.pipeline_stage_all_commands_bit, dst_stage, 0, 1, (&mb)[0..1], 0, null, 0, null);
    }

    const host_memory = vk.memory_property_host_visible_bit | vk.memory_property_host_coherent_bit;

    /// Creates a buffer bound to its own memory with the `props` flags.
    // shortcut: one VkDeviceMemory per buffer; add a sub-allocator when buffer counts near maxMemoryAllocationCount.
    fn allocate(self: *Device, size: u64, usage: u32, props: u32) Error!Allocation {
        var buffer: vk.Buffer = .null;
        // Vulkan forbids size 0; an empty Buffer still owns a 1-byte object.
        try self.check(self.fns.vkCreateBuffer(self.handle, &.{ .size = @max(size, 1), .usage = usage }, null, &buffer));
        errdefer self.fns.vkDestroyBuffer(self.handle, buffer, null);
        var req: vk.MemoryRequirements = undefined;
        self.fns.vkGetBufferMemoryRequirements(self.handle, buffer, &req);
        const type_index = self.memoryType(req.memory_type_bits, props) orelse return error.Unsupported;
        var memory: vk.DeviceMemory = .null;
        try self.check(self.fns.vkAllocateMemory(self.handle, &.{ .allocation_size = req.size, .memory_type_index = type_index }, null, &memory));
        errdefer self.fns.vkFreeMemory(self.handle, memory, null);
        try self.check(self.fns.vkBindBufferMemory(self.handle, buffer, memory, 0));
        return .{ .buffer = buffer, .memory = memory };
    }

    fn free(self: *Device, a: Allocation) void {
        self.fns.vkDestroyBuffer(self.handle, a.buffer, null);
        self.fns.vkFreeMemory(self.handle, a.memory, null); // also unmaps
    }

    fn map(self: *Device, a: Allocation) Error![*]u8 {
        var ptr: ?*anyopaque = null;
        try self.check(self.fns.vkMapMemory(self.handle, a.memory, 0, vk.whole_size, 0, &ptr));
        return @ptrCast(ptr orelse return error.OutOfMemory);
    }

    fn memoryType(self: *const Device, bits: u32, props: u32) ?u32 {
        const mp = &self.memory_properties;
        for (mp.memory_types[0..mp.memory_type_count], 0..) |t, i| {
            if (bits & (@as(u32, 1) << @intCast(i)) != 0 and t.property_flags & props == props) return @intCast(i);
        }
        return null;
    }

    fn check(self: *Device, r: vk.Result) Error!void {
        if (r == .error_device_lost) self.lost = true;
        return mapResult(r);
    }
};

/// A device-resident storage buffer (§14.11 `gpu.Buffer<T>`, untyped here;
/// `std.gpu` checks element types and lengths).
pub const Buffer = struct {
    dev: *Device,
    mem: Allocation,
    size: u64,
    /// Timeline value of the latest submission that references this buffer.
    last_use: u64 = 0,

    pub fn init(dev: *Device, size: u64) Error!Buffer {
        const usage = vk.buffer_usage_storage_buffer_bit | vk.buffer_usage_transfer_src_bit | vk.buffer_usage_transfer_dst_bit;
        const mem = dev.allocate(size, usage, vk.memory_property_device_local_bit) catch |e| switch (e) {
            error.Unsupported => try dev.allocate(size, usage, 0), // no device-local type for this buffer
            else => return e,
        };
        return .{ .dev = dev, .mem = mem, .size = size };
    }

    /// Releases host ownership now; device memory is freed once all submitted
    /// work that references the buffer completes (§11.6.4).
    pub fn deinit(self: *Buffer) void {
        self.dev.release(.{ .buffer = self.mem }, self.last_use);
        self.* = undefined;
    }

    /// Copies `src` into the buffer, ordered after all earlier submissions.
    /// Does not wait. Asserts `src.len == self.size`.
    pub fn upload(self: *Buffer, src: []const u8) Error!void {
        std.debug.assert(src.len == self.size);
        if (src.len == 0) return;
        const dev = self.dev;
        const staging = try dev.allocate(src.len, vk.buffer_usage_transfer_src_bit, Device.host_memory);
        var done_at: u64 = 0; // staging is unused by the device until submitted
        defer dev.release(.{ .buffer = staging }, done_at);
        @memcpy((try dev.map(staging))[0..src.len], src);

        const cmd = try dev.beginCommands();
        dev.fns.vkCmdCopyBuffer(cmd, staging.buffer, self.mem.buffer, 1, (&vk.BufferCopy{ .src_offset = 0, .dst_offset = 0, .size = src.len })[0..1]);
        done_at = try dev.submit(cmd, &.{self});
    }

    /// Copies the buffer into `dst`. A completion point (§11.6.4): waits for
    /// all earlier submissions and re-raises a GPU trap. Asserts
    /// `dst.len == self.size`.
    pub fn download(self: *Buffer, dst: []u8) Error!void {
        std.debug.assert(dst.len == self.size);
        const dev = self.dev;
        if (dst.len == 0) return dev.waitIdle();
        const staging = try dev.allocate(dst.len, vk.buffer_usage_transfer_dst_bit, Device.host_memory);
        var done_at: u64 = 0;
        defer dev.release(.{ .buffer = staging }, done_at);
        const mapped = try dev.map(staging);

        const cmd = try dev.beginCommands();
        dev.fns.vkCmdCopyBuffer(cmd, self.mem.buffer, staging.buffer, 1, (&vk.BufferCopy{ .src_offset = 0, .dst_offset = 0, .size = dst.len })[0..1]);
        done_at = try dev.submit(cmd, &.{self});
        try dev.complete(done_at);
        @memcpy(dst, mapped[0..dst.len]);
    }
};

/// A buffer and the memory bound to it.
pub const Allocation = struct { buffer: vk.Buffer, memory: vk.DeviceMemory };

/// Picks the first Vulkan 1.2+ physical device with a compute queue family.
fn pickPhysical(ifns: vk.InstanceFns, instance: vk.Instance) Error!struct { vk.PhysicalDevice, u32 } {
    var devices: [16]vk.PhysicalDevice = undefined;
    var count: u32 = devices.len;
    // `incomplete` just means more than 16 adapters; the first 16 are enough.
    try mapResult(ifns.vkEnumeratePhysicalDevices(instance, &count, &devices));
    for (devices[0..count]) |pd| {
        var props: vk.PhysicalDeviceProperties = undefined;
        ifns.vkGetPhysicalDeviceProperties(pd, &props);
        if (props.api_version < vk.api_version_1_2) continue;
        var families: [32]vk.QueueFamilyProperties = undefined;
        var n: u32 = families.len;
        ifns.vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, &families);
        for (families[0..n], 0..) |f, i| {
            if (f.queue_flags & vk.queue_compute_bit != 0) return .{ pd, @intCast(i) };
        }
    }
    return error.NoDevice;
}

fn mapResult(r: vk.Result) Error!void {
    return switch (r) {
        .success, .not_ready, .timeout, .incomplete => {},
        .error_device_lost => error.DeviceLost,
        .error_out_of_host_memory, .error_out_of_device_memory, .error_memory_map_failed => error.OutOfMemory,
        else => error.Unsupported,
    };
}

/// Result mapping during `Device.init`: no driver means no device.
fn initResult(r: vk.Result) Error!void {
    return switch (r) {
        .error_incompatible_driver, .error_initialization_failed => error.NoDevice,
        else => mapResult(r),
    };
}

const gpu_suffix = " (on GPU)";

/// Process trap (§9.4) for a GPU trap record (§11.7): the site's message with
/// the suffix `" (on GPU)"`. An unknown site still traps, without a location.
fn raiseGpuTrap(kind: u32, site: u32) noreturn {
    const s: TrapSite = if (site < trap_sites.len) trap_sites[site] else .{ .msg = "trap", .file = "<unknown>", .line = 0 };
    var buf: [512]u8 = undefined;
    const keep = @min(s.msg.len, buf.len - gpu_suffix.len);
    @memcpy(buf[0..keep], s.msg[0..keep]);
    @memcpy(buf[keep..][0..gpu_suffix.len], gpu_suffix);
    rt_trap.pyro_rt_trap(kind, &buf, keep + gpu_suffix.len, s.file.ptr, s.file.len, s.line);
}

const testing = std.testing;

/// The test device, or a skip when this host has no Vulkan loader or ICD.
fn testDevice() !Device {
    return Device.init(testing.allocator) catch |e| switch (e) {
        error.NoDevice => error.SkipZigTest,
        else => e,
    };
}

test "upload/download round trip" {
    var dev = try testDevice();
    defer dev.deinit();

    var src: [4096]u32 = undefined;
    for (&src, 0..) |*v, i| v.* = @truncate(i *% 2654435761);
    var buf = try Buffer.init(&dev, @sizeOf(@TypeOf(src)));
    defer buf.deinit();
    try buf.upload(std.mem.asBytes(&src));

    var dst: [4096]u32 = @splat(0);
    try buf.download(std.mem.asBytes(&dst));
    try testing.expectEqualSlices(u32, &src, &dst);

    // An empty buffer round-trips too.
    var empty = try Buffer.init(&dev, 0);
    defer empty.deinit();
    try empty.upload(&.{});
    try empty.download(&.{});
}

test "deinit while work is in flight defers destruction" {
    var dev = try testDevice();
    defer dev.deinit();

    const big = try testing.allocator.alloc(u8, 32 << 20);
    defer testing.allocator.free(big);
    @memset(big, 0xA5);

    var buf = try Buffer.init(&dev, big.len);
    try buf.upload(big);
    const mem = buf.mem;
    const in_flight = buf.last_use > dev.completed;
    buf.deinit();
    var deferred = false;
    for (dev.garbage.items) |g| switch (g.res) {
        .buffer => |a| deferred = deferred or a.buffer == mem.buffer,
        .commands => {},
    };
    try testing.expectEqual(in_flight, deferred);

    try dev.waitIdle();
    try testing.expectEqual(0, dev.garbage.items.len);

    // Device.deinit with a submission still in flight waits for it.
    var other = try Buffer.init(&dev, big.len);
    try other.upload(big);
    other.deinit();
}

test "is_lost is false on a healthy device" {
    var dev = try testDevice();
    defer dev.deinit();
    try testing.expect(!dev.isLost());
}

extern "c" fn fork() c_int;
extern "c" fn close(fd: std.c.fd_t) c_int;

test "GPU trap record becomes a process trap with (on GPU)" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var dev = try testDevice();
    defer dev.deinit();

    // The device writes the record, as a trapping kernel's winning invocation would.
    const record: TrapRecord = .{ .state = 1, .kind = @backingInt(rt_trap.TrapKind.bounds), .site = 1 };
    const cmd = try dev.beginCommands();
    dev.fns.vkCmdUpdateBuffer(cmd, dev.trap_buffer.buffer, 0, @sizeOf(TrapRecord), &record);
    try dev.wait(try dev.submit(cmd, &.{}));

    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(0, std.c.pipe(&fds));
    const pid = fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        // The child only reads host-mapped memory; it makes no Vulkan calls.
        _ = close(fds[0]);
        _ = std.c.dup2(fds[1], 2);
        trap_sites = &.{
            .{ .msg = "unused", .file = "src/a.pr", .line = 1 },
            .{ .msg = "index 9 out of bounds for length 4", .file = "src/kernel.pr", .line = 17 },
        };
        dev.checkTraps();
        std.c._exit(0); // not reached when the record is seen
    }
    _ = close(fds[1]);
    defer _ = close(fds[0]);

    var out: [256]u8 = undefined;
    var len: usize = 0;
    while (len < out.len) {
        const n = std.c.read(fds[0], out[len..].ptr, out.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    const s: u32 = @bitCast(status);
    try testing.expect(std.c.W.IFEXITED(s));
    try testing.expectEqual(rt_trap.exit_status, std.c.W.EXITSTATUS(s));
    try testing.expectEqualStrings(
        "trap[bounds]: index 9 out of bounds for length 4 (on GPU)\n  --> src/kernel.pr:17\n",
        out[0..len],
    );

    // Clear the record so this process's later completion points do not trap.
    dev.trap_record.* = .{ .state = 0, .kind = 0, .site = 0 };
}
