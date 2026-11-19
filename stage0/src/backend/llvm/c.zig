//! Hand-written bindings to the LLVM 21 C API (`llvm-c/*.h`), declared as
//! `extern fn` instead of `@cImport` so this file compiles without LLVM headers.
//!
//! Only what the backend uses is declared; add declarations as needed, copying
//! the signature from the header. Nothing here links unless referenced, and
//! every reference must sit behind `@import("build_options").llvm` (B.6.1:
//! LLVM is an optional backend).

pub const Bool = c_int;

pub const ContextRef = *opaque {};
pub const ModuleRef = *opaque {};
pub const TypeRef = *opaque {};
pub const ValueRef = *opaque {};
pub const BasicBlockRef = *opaque {};
pub const BuilderRef = *opaque {};
pub const AttributeRef = *opaque {};
pub const ExecutionEngineRef = *opaque {};

/// `LLVMOpcode` (Core.h); only the values the backend emits are listed.
pub const Opcode = enum(c_int) {
    add = 8,
    fadd = 9,
    sub = 10,
    fsub = 11,
    mul = 12,
    fmul = 13,
    udiv = 14,
    sdiv = 15,
    fdiv = 16,
    urem = 17,
    srem = 18,
    frem = 19,
    shl = 20,
    lshr = 21,
    ashr = 22,
    @"and" = 23,
    @"or" = 24,
    xor = 25,
    trunc = 30,
    zext = 31,
    sext = 32,
    uitofp = 35,
    sitofp = 36,
    fptrunc = 37,
    fpext = 38,
    ptrtoint = 39,
    inttoptr = 40,
    bitcast = 41,
    _,
};

/// `LLVMIntPredicate` (Core.h).
pub const IntPredicate = enum(c_int) { eq = 32, ne, ugt, uge, ult, ule, sgt, sge, slt, sle };

/// `LLVMRealPredicate` (Core.h).
pub const RealPredicate = enum(c_int) { false, oeq, ogt, oge, olt, ole, one, ord, uno, ueq, ugt, uge, ult, ule, une, true };

/// `LLVMFastMathFlags` (Core.h): every flag set.
pub const fast_math_all: c_uint = 0x7f;

/// `LLVMAttributeIndex` values; parameter `i` (0-based) is index `i + 1`.
pub const attribute_return_index: c_uint = 0;
pub const attribute_function_index: c_uint = ~@as(c_uint, 0);

/// `LLVMAtomicOrdering` (Core.h).
pub const AtomicOrdering = enum(c_int) { not_atomic = 0, unordered = 1, monotonic = 2, acquire = 4, release = 5, acq_rel = 6, seq_cst = 7 };

/// `LLVMAtomicRMWBinOp` (Core.h); only the integer and exchange operations.
pub const AtomicRMWBinOp = enum(c_int) { xchg, add, sub, @"and", nand, @"or", xor, max, min, umax, umin, _ };

/// `LLVMTailCallKind` (Core.h).
pub const TailCallKind = enum(c_int) { none, tail, must_tail, no_tail };

/// `LLVMVerifierFailureAction` (Analysis.h).
pub const VerifierFailureAction = enum(c_int) { abort_process, print_message, return_status };

// Core.h: contexts, modules, types
pub extern fn LLVMContextCreate() ContextRef;
pub extern fn LLVMContextDispose(C: ContextRef) void;
pub extern fn LLVMModuleCreateWithNameInContext(ModuleID: [*:0]const u8, C: ContextRef) ModuleRef;
pub extern fn LLVMDisposeModule(M: ModuleRef) void;
pub extern fn LLVMPrintModuleToString(M: ModuleRef) [*:0]u8;
pub extern fn LLVMDisposeMessage(Message: [*:0]u8) void;
pub extern fn LLVMIntTypeInContext(C: ContextRef, NumBits: c_uint) TypeRef;
pub extern fn LLVMFloatTypeInContext(C: ContextRef) TypeRef;
pub extern fn LLVMDoubleTypeInContext(C: ContextRef) TypeRef;
pub extern fn LLVMVoidTypeInContext(C: ContextRef) TypeRef;
pub extern fn LLVMPointerTypeInContext(C: ContextRef, AddressSpace: c_uint) TypeRef;
pub extern fn LLVMVectorType(ElementType: TypeRef, ElementCount: c_uint) TypeRef;
pub extern fn LLVMArrayType2(ElementType: TypeRef, ElementCount: u64) TypeRef;
pub extern fn LLVMFunctionType(ReturnType: TypeRef, ParamTypes: [*]const TypeRef, ParamCount: c_uint, IsVarArg: Bool) TypeRef;

// Core.h: values, functions, attributes, blocks
pub extern fn LLVMAddFunction(M: ModuleRef, Name: [*:0]const u8, FunctionTy: TypeRef) ValueRef;
pub extern fn LLVMGetParam(Fn: ValueRef, Index: c_uint) ValueRef;
pub extern fn LLVMSetValueName2(Val: ValueRef, Name: [*]const u8, NameLen: usize) void;
pub extern fn LLVMIsAInstruction(Val: ValueRef) ?ValueRef;
pub extern fn LLVMConstInt(IntTy: TypeRef, N: c_ulonglong, SignExtend: Bool) ValueRef;
pub extern fn LLVMConstReal(RealTy: TypeRef, N: f64) ValueRef;
pub extern fn LLVMConstNull(Ty: TypeRef) ValueRef;
pub extern fn LLVMGetPoison(Ty: TypeRef) ValueRef;
pub extern fn LLVMConstVector(ScalarConstantVals: [*]const ValueRef, Size: c_uint) ValueRef;
pub extern fn LLVMConstStringInContext2(C: ContextRef, Str: [*]const u8, Length: usize, DontNullTerminate: Bool) ValueRef;
pub extern fn LLVMAddGlobal(M: ModuleRef, Ty: TypeRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMSetInitializer(GlobalVar: ValueRef, ConstantVal: ValueRef) void;
pub extern fn LLVMSetGlobalConstant(GlobalVar: ValueRef, IsConstant: Bool) void;
pub extern fn LLVMSetAlignment(V: ValueRef, Bytes: c_uint) void;
pub extern fn LLVMGetGlobalParent(Global: ValueRef) ModuleRef;
pub extern fn LLVMGlobalGetValueType(Global: ValueRef) TypeRef;
pub extern fn LLVMGetNamedFunction(M: ModuleRef, Name: [*:0]const u8) ?ValueRef;
pub extern fn LLVMLookupIntrinsicID(Name: [*]const u8, NameLen: usize) c_uint;
pub extern fn LLVMGetIntrinsicDeclaration(Mod: ModuleRef, ID: c_uint, ParamTypes: [*]const TypeRef, ParamCount: usize) ValueRef;
pub extern fn LLVMIntrinsicGetType(Ctx: ContextRef, ID: c_uint, ParamTypes: [*]const TypeRef, ParamCount: usize) TypeRef;
pub extern fn LLVMGetEnumAttributeKindForName(Name: [*]const u8, SLen: usize) c_uint;
pub extern fn LLVMCreateEnumAttribute(C: ContextRef, KindID: c_uint, Val: u64) AttributeRef;
pub extern fn LLVMAddAttributeAtIndex(F: ValueRef, Idx: c_uint, A: AttributeRef) void;
pub extern fn LLVMAppendBasicBlockInContext(C: ContextRef, Fn: ValueRef, Name: [*:0]const u8) BasicBlockRef;
pub extern fn LLVMMoveBasicBlockAfter(BB: BasicBlockRef, MovePos: BasicBlockRef) void;
pub extern fn LLVMAddIncoming(PhiNode: ValueRef, IncomingValues: [*]const ValueRef, IncomingBlocks: [*]const BasicBlockRef, Count: c_uint) void;
pub extern fn LLVMAddCase(Switch: ValueRef, OnVal: ValueRef, Dest: BasicBlockRef) void;
pub extern fn LLVMSetNUW(ArithInst: ValueRef, HasNUW: Bool) void;
pub extern fn LLVMSetNSW(ArithInst: ValueRef, HasNSW: Bool) void;
pub extern fn LLVMCanValueUseFastMathFlags(Inst: ValueRef) Bool;
pub extern fn LLVMSetFastMathFlags(FPMathInst: ValueRef, FMF: c_uint) void;

// Core.h: instruction builder
pub extern fn LLVMCreateBuilderInContext(C: ContextRef) BuilderRef;
pub extern fn LLVMDisposeBuilder(Builder: BuilderRef) void;
pub extern fn LLVMPositionBuilderAtEnd(Builder: BuilderRef, Block: BasicBlockRef) void;
pub extern fn LLVMGetInsertBlock(Builder: BuilderRef) BasicBlockRef;
pub extern fn LLVMBuildBinOp(B: BuilderRef, Op: Opcode, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildFNeg(B: BuilderRef, V: ValueRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildICmp(B: BuilderRef, Op: IntPredicate, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildFCmp(B: BuilderRef, Op: RealPredicate, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildCast(B: BuilderRef, Op: Opcode, Val: ValueRef, DestTy: TypeRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildPhi(B: BuilderRef, Ty: TypeRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildBr(B: BuilderRef, Dest: BasicBlockRef) ValueRef;
pub extern fn LLVMBuildCondBr(B: BuilderRef, If: ValueRef, Then: BasicBlockRef, Else: BasicBlockRef) ValueRef;
pub extern fn LLVMBuildSwitch(B: BuilderRef, V: ValueRef, Else: BasicBlockRef, NumCases: c_uint) ValueRef;
pub extern fn LLVMBuildRet(B: BuilderRef, V: ValueRef) ValueRef;
pub extern fn LLVMBuildRetVoid(B: BuilderRef) ValueRef;
pub extern fn LLVMBuildUnreachable(B: BuilderRef) ValueRef;
pub extern fn LLVMBuildAlloca(B: BuilderRef, Ty: TypeRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildLoad2(B: BuilderRef, Ty: TypeRef, PointerVal: ValueRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildStore(B: BuilderRef, Val: ValueRef, Ptr: ValueRef) ValueRef;
pub extern fn LLVMBuildGEP2(B: BuilderRef, Ty: TypeRef, Pointer: ValueRef, Indices: [*]const ValueRef, NumIndices: c_uint, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildMemSet(B: BuilderRef, Ptr: ValueRef, Val: ValueRef, Len: ValueRef, Align: c_uint) ValueRef;
pub extern fn LLVMBuildMemCpy(B: BuilderRef, Dst: ValueRef, DstAlign: c_uint, Src: ValueRef, SrcAlign: c_uint, Size: ValueRef) ValueRef;
pub extern fn LLVMSetVolatile(MemoryAccessInst: ValueRef, IsVolatile: Bool) void;
pub extern fn LLVMSetOrdering(MemoryAccessInst: ValueRef, Ordering: AtomicOrdering) void;
pub extern fn LLVMBuildAtomicRMW(B: BuilderRef, op: AtomicRMWBinOp, PTR: ValueRef, Val: ValueRef, ordering: AtomicOrdering, singleThread: Bool) ValueRef;
pub extern fn LLVMBuildAtomicCmpXchg(B: BuilderRef, Ptr: ValueRef, Cmp: ValueRef, New: ValueRef, SuccessOrdering: AtomicOrdering, FailureOrdering: AtomicOrdering, SingleThread: Bool) ValueRef;
pub extern fn LLVMBuildFence(B: BuilderRef, ordering: AtomicOrdering, singleThread: Bool, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildCall2(B: BuilderRef, Ty: TypeRef, Fn: ValueRef, Args: [*]const ValueRef, NumArgs: c_uint, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMSetTailCallKind(CallInst: ValueRef, kind: TailCallKind) void;
pub extern fn LLVMBuildExtractValue(B: BuilderRef, AggVal: ValueRef, Index: c_uint, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildExtractElement(B: BuilderRef, VecVal: ValueRef, Index: ValueRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildInsertElement(B: BuilderRef, VecVal: ValueRef, EltVal: ValueRef, Index: ValueRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildShuffleVector(B: BuilderRef, V1: ValueRef, V2: ValueRef, Mask: ValueRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildSelect(B: BuilderRef, If: ValueRef, Then: ValueRef, Else: ValueRef, Name: [*:0]const u8) ValueRef;

// Analysis.h
pub extern fn LLVMVerifyModule(M: ModuleRef, Action: VerifierFailureAction, OutMessage: *?[*:0]u8) Bool;

// ExecutionEngine.h (MCJIT)
pub extern fn LLVMLinkInMCJIT() void;
pub extern fn LLVMCreateExecutionEngineForModule(OutEE: *ExecutionEngineRef, M: ModuleRef, OutError: *?[*:0]u8) Bool;
pub extern fn LLVMDisposeExecutionEngine(EE: ExecutionEngineRef) void;
pub extern fn LLVMGetFunctionAddress(EE: ExecutionEngineRef, Name: [*:0]const u8) u64;

// Support.h
pub extern fn LLVMAddSymbol(symbolName: [*:0]const u8, symbolValue: *const anyopaque) void;

// Target.h: per-target initialisation (`LLVMInitializeNativeTarget` is a
// header-only inline, so callers pick the host's functions themselves).
pub extern fn LLVMInitializeX86TargetInfo() void;
pub extern fn LLVMInitializeX86Target() void;
pub extern fn LLVMInitializeX86TargetMC() void;
pub extern fn LLVMInitializeX86AsmPrinter() void;
pub extern fn LLVMInitializeAArch64TargetInfo() void;
pub extern fn LLVMInitializeAArch64Target() void;
pub extern fn LLVMInitializeAArch64TargetMC() void;
pub extern fn LLVMInitializeAArch64AsmPrinter() void;
