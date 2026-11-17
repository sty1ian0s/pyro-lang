//! Hand-written Vulkan 1.2 declarations: only the handles, structs, enums and
//! entry points the GPU runtime uses. Nothing links against a Vulkan SDK; the
//! loader `libvulkan.so.1` is opened at run time and every entry point is
//! fetched through `vkGetInstanceProcAddr` / `vkGetDeviceProcAddr`.
//!
//! Layouts follow `vulkan_core.h` on LP64 targets. Bitmask and enum values are
//! plain integers with named constants, as in C.

const std = @import("std");

pub const Instance = *opaque {};
pub const PhysicalDevice = *opaque {};
pub const Device = *opaque {};
pub const Queue = *opaque {};
pub const CommandBuffer = *opaque {};

/// Non-dispatchable handles are 64-bit on every platform.
pub const Buffer = enum(u64) { null = 0, _ };
pub const DeviceMemory = enum(u64) { null = 0, _ };
pub const CommandPool = enum(u64) { null = 0, _ };
pub const Semaphore = enum(u64) { null = 0, _ };
pub const Fence = enum(u64) { null = 0, _ };

pub const Result = enum(i32) {
    success = 0,
    not_ready = 1,
    timeout = 2,
    incomplete = 5,
    error_out_of_host_memory = -1,
    error_out_of_device_memory = -2,
    error_initialization_failed = -3,
    error_device_lost = -4,
    error_memory_map_failed = -5,
    error_layer_not_present = -6,
    error_extension_not_present = -7,
    error_feature_not_present = -8,
    error_incompatible_driver = -9,
    _,
};

pub const StructureType = enum(i32) {
    application_info = 0,
    instance_create_info = 1,
    device_queue_create_info = 2,
    device_create_info = 3,
    submit_info = 4,
    memory_allocate_info = 5,
    semaphore_create_info = 9,
    buffer_create_info = 12,
    command_pool_create_info = 39,
    command_buffer_allocate_info = 40,
    command_buffer_begin_info = 42,
    memory_barrier = 46,
    physical_device_timeline_semaphore_features = 1000207000,
    semaphore_type_create_info = 1000207002,
    timeline_semaphore_submit_info = 1000207003,
    semaphore_wait_info = 1000207004,
};

pub fn makeApiVersion(major: u32, minor: u32, patch: u32) u32 {
    return major << 22 | minor << 12 | patch;
}

pub const api_version_1_2 = makeApiVersion(1, 2, 0);
pub const whole_size: u64 = ~@as(u64, 0);

pub const queue_compute_bit: u32 = 0x2;

pub const memory_property_device_local_bit: u32 = 0x1;
pub const memory_property_host_visible_bit: u32 = 0x2;
pub const memory_property_host_coherent_bit: u32 = 0x4;

pub const buffer_usage_transfer_src_bit: u32 = 0x1;
pub const buffer_usage_transfer_dst_bit: u32 = 0x2;
pub const buffer_usage_storage_buffer_bit: u32 = 0x20;

pub const command_pool_create_transient_bit: u32 = 0x1;
pub const command_buffer_usage_one_time_submit_bit: u32 = 0x1;

pub const pipeline_stage_all_commands_bit: u32 = 0x10000;
pub const pipeline_stage_host_bit: u32 = 0x4000;

pub const access_host_read_bit: u32 = 0x2000;
pub const access_memory_read_bit: u32 = 0x8000;
pub const access_memory_write_bit: u32 = 0x10000;

pub const semaphore_type_timeline: u32 = 1;

pub const PhysicalDeviceType = enum(u32) { other = 0, integrated_gpu = 1, discrete_gpu = 2, virtual_gpu = 3, cpu = 4, _ };

pub const ApplicationInfo = extern struct {
    s_type: StructureType = .application_info,
    p_next: ?*const anyopaque = null,
    p_application_name: ?[*:0]const u8 = null,
    application_version: u32 = 0,
    p_engine_name: ?[*:0]const u8 = null,
    engine_version: u32 = 0,
    api_version: u32,
};

pub const InstanceCreateInfo = extern struct {
    s_type: StructureType = .instance_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    p_application_info: ?*const ApplicationInfo = null,
    enabled_layer_count: u32 = 0,
    pp_enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    pp_enabled_extension_names: ?[*]const [*:0]const u8 = null,
};

/// Only the leading fields are named; `rest` covers `limits` and
/// `sparseProperties` (824 bytes in total), with room to spare.
pub const PhysicalDeviceProperties = extern struct {
    api_version: u32,
    driver_version: u32,
    vendor_id: u32,
    device_id: u32,
    device_type: PhysicalDeviceType,
    device_name: [256]u8,
    pipeline_cache_uuid: [16]u8,
    rest: [1024]u8 align(8),
};

pub const Extent3D = extern struct { width: u32, height: u32, depth: u32 };

pub const QueueFamilyProperties = extern struct {
    queue_flags: u32,
    queue_count: u32,
    timestamp_valid_bits: u32,
    min_image_transfer_granularity: Extent3D,
};

pub const MemoryType = extern struct { property_flags: u32, heap_index: u32 };
pub const MemoryHeap = extern struct { size: u64, flags: u32 };

pub const PhysicalDeviceMemoryProperties = extern struct {
    memory_type_count: u32,
    memory_types: [32]MemoryType,
    memory_heap_count: u32,
    memory_heaps: [16]MemoryHeap,
};

pub const DeviceQueueCreateInfo = extern struct {
    s_type: StructureType = .device_queue_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    queue_family_index: u32,
    queue_count: u32,
    p_queue_priorities: [*]const f32,
};

pub const PhysicalDeviceTimelineSemaphoreFeatures = extern struct {
    s_type: StructureType = .physical_device_timeline_semaphore_features,
    p_next: ?*anyopaque = null,
    timeline_semaphore: u32,
};

pub const DeviceCreateInfo = extern struct {
    s_type: StructureType = .device_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    queue_create_info_count: u32,
    p_queue_create_infos: [*]const DeviceQueueCreateInfo,
    enabled_layer_count: u32 = 0,
    pp_enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    pp_enabled_extension_names: ?[*]const [*:0]const u8 = null,
    p_enabled_features: ?*const anyopaque = null,
};

pub const BufferCreateInfo = extern struct {
    s_type: StructureType = .buffer_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    size: u64,
    usage: u32,
    sharing_mode: u32 = 0, // VK_SHARING_MODE_EXCLUSIVE
    queue_family_index_count: u32 = 0,
    p_queue_family_indices: ?[*]const u32 = null,
};

pub const MemoryRequirements = extern struct { size: u64, alignment: u64, memory_type_bits: u32 };

pub const MemoryAllocateInfo = extern struct {
    s_type: StructureType = .memory_allocate_info,
    p_next: ?*const anyopaque = null,
    allocation_size: u64,
    memory_type_index: u32,
};

pub const CommandPoolCreateInfo = extern struct {
    s_type: StructureType = .command_pool_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    queue_family_index: u32,
};

pub const CommandBufferAllocateInfo = extern struct {
    s_type: StructureType = .command_buffer_allocate_info,
    p_next: ?*const anyopaque = null,
    command_pool: CommandPool,
    level: u32 = 0, // VK_COMMAND_BUFFER_LEVEL_PRIMARY
    command_buffer_count: u32,
};

pub const CommandBufferBeginInfo = extern struct {
    s_type: StructureType = .command_buffer_begin_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    p_inheritance_info: ?*const anyopaque = null,
};

pub const BufferCopy = extern struct { src_offset: u64, dst_offset: u64, size: u64 };

pub const MemoryBarrier = extern struct {
    s_type: StructureType = .memory_barrier,
    p_next: ?*const anyopaque = null,
    src_access_mask: u32,
    dst_access_mask: u32,
};

pub const SemaphoreTypeCreateInfo = extern struct {
    s_type: StructureType = .semaphore_type_create_info,
    p_next: ?*const anyopaque = null,
    semaphore_type: u32,
    initial_value: u64,
};

pub const SemaphoreCreateInfo = extern struct {
    s_type: StructureType = .semaphore_create_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
};

pub const TimelineSemaphoreSubmitInfo = extern struct {
    s_type: StructureType = .timeline_semaphore_submit_info,
    p_next: ?*const anyopaque = null,
    wait_semaphore_value_count: u32 = 0,
    p_wait_semaphore_values: ?[*]const u64 = null,
    signal_semaphore_value_count: u32 = 0,
    p_signal_semaphore_values: ?[*]const u64 = null,
};

pub const SubmitInfo = extern struct {
    s_type: StructureType = .submit_info,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32 = 0,
    p_wait_semaphores: ?[*]const Semaphore = null,
    p_wait_dst_stage_mask: ?[*]const u32 = null,
    command_buffer_count: u32 = 0,
    p_command_buffers: ?[*]const CommandBuffer = null,
    signal_semaphore_count: u32 = 0,
    p_signal_semaphores: ?[*]const Semaphore = null,
};

pub const SemaphoreWaitInfo = extern struct {
    s_type: StructureType = .semaphore_wait_info,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    semaphore_count: u32,
    p_semaphores: [*]const Semaphore,
    p_values: [*]const u64,
};

/// `const VkAllocationCallbacks*`; the runtime always passes null.
const Alloc = ?*const anyopaque;
const VoidFn = *const fn () callconv(.c) void;

pub const PfnGetInstanceProcAddr = *const fn (?Instance, [*:0]const u8) callconv(.c) ?VoidFn;

/// Entry points fetched with a null instance.
pub const GlobalFns = struct {
    vkCreateInstance: *const fn (*const InstanceCreateInfo, Alloc, *Instance) callconv(.c) Result,
};

pub const InstanceFns = struct {
    vkDestroyInstance: *const fn (Instance, Alloc) callconv(.c) void,
    vkEnumeratePhysicalDevices: *const fn (Instance, *u32, ?[*]PhysicalDevice) callconv(.c) Result,
    vkGetPhysicalDeviceProperties: *const fn (PhysicalDevice, *PhysicalDeviceProperties) callconv(.c) void,
    vkGetPhysicalDeviceQueueFamilyProperties: *const fn (PhysicalDevice, *u32, ?[*]QueueFamilyProperties) callconv(.c) void,
    vkGetPhysicalDeviceMemoryProperties: *const fn (PhysicalDevice, *PhysicalDeviceMemoryProperties) callconv(.c) void,
    vkCreateDevice: *const fn (PhysicalDevice, *const DeviceCreateInfo, Alloc, *Device) callconv(.c) Result,
    vkGetDeviceProcAddr: *const fn (Device, [*:0]const u8) callconv(.c) ?VoidFn,
};

pub const DeviceFns = struct {
    vkDestroyDevice: *const fn (Device, Alloc) callconv(.c) void,
    vkGetDeviceQueue: *const fn (Device, u32, u32, *Queue) callconv(.c) void,
    vkDeviceWaitIdle: *const fn (Device) callconv(.c) Result,
    vkCreateBuffer: *const fn (Device, *const BufferCreateInfo, Alloc, *Buffer) callconv(.c) Result,
    vkDestroyBuffer: *const fn (Device, Buffer, Alloc) callconv(.c) void,
    vkGetBufferMemoryRequirements: *const fn (Device, Buffer, *MemoryRequirements) callconv(.c) void,
    vkAllocateMemory: *const fn (Device, *const MemoryAllocateInfo, Alloc, *DeviceMemory) callconv(.c) Result,
    vkFreeMemory: *const fn (Device, DeviceMemory, Alloc) callconv(.c) void,
    vkBindBufferMemory: *const fn (Device, Buffer, DeviceMemory, u64) callconv(.c) Result,
    vkMapMemory: *const fn (Device, DeviceMemory, u64, u64, u32, *?*anyopaque) callconv(.c) Result,
    vkCreateCommandPool: *const fn (Device, *const CommandPoolCreateInfo, Alloc, *CommandPool) callconv(.c) Result,
    vkDestroyCommandPool: *const fn (Device, CommandPool, Alloc) callconv(.c) void,
    vkAllocateCommandBuffers: *const fn (Device, *const CommandBufferAllocateInfo, [*]CommandBuffer) callconv(.c) Result,
    vkFreeCommandBuffers: *const fn (Device, CommandPool, u32, [*]const CommandBuffer) callconv(.c) void,
    vkBeginCommandBuffer: *const fn (CommandBuffer, *const CommandBufferBeginInfo) callconv(.c) Result,
    vkEndCommandBuffer: *const fn (CommandBuffer) callconv(.c) Result,
    vkCmdCopyBuffer: *const fn (CommandBuffer, Buffer, Buffer, u32, [*]const BufferCopy) callconv(.c) void,
    vkCmdUpdateBuffer: *const fn (CommandBuffer, Buffer, u64, u64, *const anyopaque) callconv(.c) void,
    vkCmdPipelineBarrier: *const fn (CommandBuffer, u32, u32, u32, u32, ?[*]const MemoryBarrier, u32, ?*const anyopaque, u32, ?*const anyopaque) callconv(.c) void,
    vkQueueSubmit: *const fn (Queue, u32, [*]const SubmitInfo, Fence) callconv(.c) Result,
    vkCreateSemaphore: *const fn (Device, *const SemaphoreCreateInfo, Alloc, *Semaphore) callconv(.c) Result,
    vkDestroySemaphore: *const fn (Device, Semaphore, Alloc) callconv(.c) void,
    vkGetSemaphoreCounterValue: *const fn (Device, Semaphore, *u64) callconv(.c) Result,
    vkWaitSemaphores: *const fn (Device, *const SemaphoreWaitInfo, u64) callconv(.c) Result,
};

/// Fills every field of the function table `T` (field name = Vulkan entry point
/// name) through `get(handle, name)`. Returns null if any entry point is missing.
pub fn load(comptime T: type, handle: anytype, get: anytype) ?T {
    var fns: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        @field(fns, name) = @ptrCast(get(handle, name.ptr) orelse return null);
    }
    return fns;
}

test "struct layouts match vulkan_core.h on LP64" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try std.testing.expectEqual(48, @sizeOf(ApplicationInfo));
    try std.testing.expectEqual(64, @sizeOf(InstanceCreateInfo));
    try std.testing.expectEqual(72, @sizeOf(DeviceCreateInfo));
    try std.testing.expectEqual(56, @sizeOf(BufferCreateInfo));
    try std.testing.expectEqual(72, @sizeOf(SubmitInfo));
    try std.testing.expectEqual(24, @sizeOf(QueueFamilyProperties));
    try std.testing.expectEqual(520, @sizeOf(PhysicalDeviceMemoryProperties));
    try std.testing.expectEqual(40, @sizeOf(SemaphoreWaitInfo));
    try std.testing.expect(@sizeOf(PhysicalDeviceProperties) >= 824);
    try std.testing.expectEqual(296, @offsetOf(PhysicalDeviceProperties, "rest"));
}
