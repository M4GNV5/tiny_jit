/**
Copyright: Copyright (c) 2017-2018 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module lir_amd64;

import std.bitmanip : bitfields;
import std.stdio;
import std.format;

import all;
import amd64asm;

struct PhysicalRegister
{
	string name;
	IrIndex index;
}

struct MachineInfo
{
	PhysicalRegister[] registers;
	InstrInfo[] instrInfo;
}

__gshared MachineInfo mach_info_amd64 = MachineInfo(
	[
		PhysicalRegister("ax", amd64_reg.ax),
		PhysicalRegister("cx", amd64_reg.cx),
		PhysicalRegister("dx", amd64_reg.dx),
		PhysicalRegister("bx", amd64_reg.bx),
		PhysicalRegister("sp", amd64_reg.sp),
		PhysicalRegister("bp", amd64_reg.bp),
		PhysicalRegister("si", amd64_reg.si),
		PhysicalRegister("di", amd64_reg.di),
		PhysicalRegister("r8", amd64_reg.r8),
		PhysicalRegister("r9", amd64_reg.r9),
		PhysicalRegister("r10", amd64_reg.r10),
		PhysicalRegister("r11", amd64_reg.r11),
		PhysicalRegister("r12", amd64_reg.r12),
		PhysicalRegister("r13", amd64_reg.r13),
		PhysicalRegister("r14", amd64_reg.r14),
		PhysicalRegister("r15", amd64_reg.r15),
	],
	gatherInfos()
);

enum amd64_reg : IrIndex {
	ax = IrIndex(0, IrValueKind.physicalRegister),
	cx = IrIndex(1, IrValueKind.physicalRegister),
	dx = IrIndex(2, IrValueKind.physicalRegister),
	bx = IrIndex(3, IrValueKind.physicalRegister),
	sp = IrIndex(4, IrValueKind.physicalRegister),
	bp = IrIndex(5, IrValueKind.physicalRegister),
	si = IrIndex(6, IrValueKind.physicalRegister),
	di = IrIndex(7, IrValueKind.physicalRegister),
	r8 = IrIndex(8, IrValueKind.physicalRegister),
	r9 = IrIndex(9, IrValueKind.physicalRegister),
	r10 = IrIndex(10, IrValueKind.physicalRegister),
	r11 = IrIndex(11, IrValueKind.physicalRegister),
	r12 = IrIndex(12, IrValueKind.physicalRegister),
	r13 = IrIndex(13, IrValueKind.physicalRegister),
	r14 = IrIndex(14, IrValueKind.physicalRegister),
	r15 = IrIndex(15, IrValueKind.physicalRegister),
}

struct CallConv
{
	IrIndex[] paramsInRegs;
	IrIndex returnReg;
	IrIndex[] volatileRegs;
	IrIndex[] allocatableRegs;
	IrIndex[] calleeSaved;
	/// Not included into allocatableRegs
	/// Can be used as frame pointer when
	/// frame pointer is enabled for the function, or
	/// can be used as allocatable register if not
	IrIndex framePointer;
	IrIndex stackPointer;

	bool isParamOnStack(size_t parIndex) {
		return parIndex >= paramsInRegs.length;
	}
}

__gshared CallConv win64_call_conv = CallConv
(
	// parameters in registers
	[amd64_reg.cx, amd64_reg.dx, amd64_reg.r8, amd64_reg.r9],

	amd64_reg.ax,  // return reg

	[amd64_reg.ax, // volatile regs
	amd64_reg.cx,
	amd64_reg.dx,
	amd64_reg.r8,
	amd64_reg.r9,
	amd64_reg.r10,
	amd64_reg.r11],

	// avaliable for allocation
	[amd64_reg.ax, // volatile regs, zero cost
	amd64_reg.cx,
	amd64_reg.dx,
	amd64_reg.r8,
	amd64_reg.r9,
	amd64_reg.r10,
	amd64_reg.r11,

	// callee saved
	amd64_reg.bx, // need to save/restore to use
	amd64_reg.si,
	amd64_reg.di,
	amd64_reg.r12,
	amd64_reg.r13,
	amd64_reg.r14,
	amd64_reg.r15],

	[amd64_reg.bx, // callee saved regs
	amd64_reg.si,
	amd64_reg.di,
	amd64_reg.r12,
	amd64_reg.r13,
	amd64_reg.r14,
	amd64_reg.r15],

	amd64_reg.bp, // frame pointer
	amd64_reg.sp, // stack pointer
);

private alias _ii = InstrInfo;
///
enum Amd64Opcode : ushort {
	@_ii(1,2,IFLG.isTwoOperandForm) add,
	@_ii(1,2,IFLG.isTwoOperandForm) sub,
	@_ii(1,2,IFLG.isTwoOperandForm) imul,
	@_ii(1,2,IFLG.isTwoOperandForm) or,
	@_ii(1,2,IFLG.isTwoOperandForm) and,
	@_ii(1,2,IFLG.isTwoOperandForm) xor,
	@_ii() mul,
	@_ii() div,
	@_ii() lea,

	@_ii(0,1,IFLG.isMov) mov, // rr, ri
	@_ii(0,1,IFLG.isLoad) load,
	@_ii(0,2,IFLG.isStore) store,
	@_ii() movsx,
	@_ii() movzx,
	@_ii() xchg,

	@_ii() not,
	@_ii() neg,

	@_ii() cmp,
	@_ii() test,

	// machine specific branches
	@_ii(0,0,IFLG.isJump) jmp,
	@_ii() jcc,
	// high-level branches
	@_ii(0,2,IFLG.isBranch) bin_branch,
	@_ii(0,2,IFLG.isBranch) un_branch,

	@_ii() setcc,

	@_ii(0,0,IFLG.isCall) call,
	@_ii() ret,

	@_ii() pop,
	@_ii() push,
}

InstrInfo[] gatherInfos()
{
	InstrInfo[] res = new InstrInfo[__traits(allMembers, Amd64Opcode).length];
	foreach (i, m; __traits(allMembers, Amd64Opcode))
	{
		res[i] = __traits(getAttributes, mixin("Amd64Opcode."~m))[0];
	}
	return res;
}

alias LirAmd64Instr_add = IrGenericInstr!(Amd64Opcode.add, 2, IFLG.hasResult | IFLG.isTwoOperandForm); // arg0 = arg0 + arg1
alias LirAmd64Instr_sub = IrGenericInstr!(Amd64Opcode.sub, 2, IFLG.hasResult | IFLG.isTwoOperandForm); // arg0 = arg0 - arg1
alias LirAmd64Instr_imul = IrGenericInstr!(Amd64Opcode.imul, 2, IFLG.hasResult | IFLG.isTwoOperandForm);
alias LirAmd64Instr_xor = IrGenericInstr!(Amd64Opcode.xor, 2, IFLG.hasResult | IFLG.isTwoOperandForm);
alias LirAmd64Instr_cmp = IrGenericInstr!(Amd64Opcode.cmp, 2);
alias LirAmd64Instr_jcc = IrGenericInstr!(Amd64Opcode.jcc, 1);
alias LirAmd64Instr_jmp = IrGenericInstr!(Amd64Opcode.jmp, 0);
alias LirAmd64Instr_bin_branch = IrGenericInstr!(Amd64Opcode.bin_branch, 2, IFLG.hasCondition);
alias LirAmd64Instr_un_branch = IrGenericInstr!(Amd64Opcode.un_branch, 1, IFLG.hasCondition);
alias LirAmd64Instr_test = IrGenericInstr!(Amd64Opcode.test, 1);
alias LirAmd64Instr_push = IrGenericInstr!(Amd64Opcode.push, 0);
alias LirAmd64Instr_return = IrGenericInstr!(Amd64Opcode.ret, 0);
alias LirAmd64Instr_mov = IrGenericInstr!(Amd64Opcode.mov, 1, IFLG.hasResult); // mov rr/ri
alias LirAmd64Instr_load = IrGenericInstr!(Amd64Opcode.load, 1, IFLG.hasResult); // mov rm
alias LirAmd64Instr_store = IrGenericInstr!(Amd64Opcode.store, 2); // mov mr/mi
alias LirAmd64Instr_xchg = IrGenericInstr!(Amd64Opcode.xchg, 2); // xchg mr/mr
// call layout
// - header
// - result (if callee is non-void)
// - arg0
// - arg1
// - ...
// - argN
///
alias LirAmd64Instr_call = IrGenericInstr!(Amd64Opcode.call, 0, IFLG.hasVariadicArgs | IFLG.hasVariadicResult);

Condition[] IrBinCondToAmd64Condition = [
	Condition.E,  // eq
	Condition.NE, // ne
	Condition.G,  // g
	Condition.GE, // ge
	Condition.L,  // l
	Condition.LE, // le
];

Condition[] IrUnCondToAmd64Condition = [
	Condition.Z,  // zero
	Condition.NZ, // not_zero
];

IrDumpHandlers lirAmd64DumpHandlers = IrDumpHandlers(&dumpAmd64Instr, &dumpLirAmd64Index);

void dumpFunction_lir_amd64(ref IrFunction lir, ref CompilationContext ctx)
{
	FuncDumpSettings settings;
	settings.handlers = &lirAmd64DumpHandlers;
	dumpFunction(lir, ctx, settings);
}

void dumpAmd64Instr(ref InstrPrintInfo p)
{
	switch(p.instrHeader.op)
	{
		case Amd64Opcode.call:
			dumpCall(p);
			break;
		case Amd64Opcode.bin_branch:
			dumpBinBranch(p);
			break;
		case Amd64Opcode.un_branch:
			dumpUnBranch(p);
			break;
		case Amd64Opcode.jmp: dumpJmp(p); break;
		case Amd64Opcode.jcc:
			p.sink.putf("    j%s ", cast(Condition)p.instrHeader.cond);
			p.dumpIndex(p.instrHeader.args[0]);
			break;
		default:
			if (p.instrHeader.hasResult)
			{
				p.sink.put("    ");
				p.dumpIndex(p.instrHeader.result);
				p.sink.putf(" = %s", cast(Amd64Opcode)p.instrHeader.op);
			}
			else  p.sink.putf("    %s", cast(Amd64Opcode)p.instrHeader.op);

			if (p.instrHeader.args.length > 0) p.sink.put(" ");
			foreach (i, IrIndex arg; p.instrHeader.args)
			{
				if (i > 0) p.sink.put(", ");
				p.dumpIndex(arg);
			}
			break;
	}
}

void dumpLirAmd64Index(ref InstrPrintInfo p, IrIndex i)
{
	final switch(i.kind) with(IrValueKind) {
		case none: p.sink.put("<null>"); break;
		case listItem: p.sink.putf("l.%s", i.storageUintIndex); break;
		case instruction: p.sink.putf("i.%s", i.storageUintIndex); break;
		case basicBlock: p.sink.putf("@%s", i.storageUintIndex); break;
		case constant: p.sink.putf("%s", p.context.getConstant(i).i64); break;
		case phi: p.sink.putf("phi.%s", i.storageUintIndex); break;
		case memoryAddress: p.sink.putf("m.%s", i.storageUintIndex); break;
		case stackSlot: p.sink.putf("s.%s", i.storageUintIndex); break;
		case virtualRegister: p.sink.putf("v.%s", i.storageUintIndex); break;
		// TODO, HACK: 32-bit version of register is hardcoded here
		case physicalRegister: p.sink.put("e"); p.sink.put(mach_info_amd64.registers[i.storageUintIndex].name); break;
	}
}

///
struct LirBuilder
{
	CompilationContext* context;
	IrFunction* ir;
	IrFunction* lir;

	/// Must be called before LIR gen pass
	void begin(IrFunction* lir, IrFunction* ir, CompilationContext* context) {
		this.context = context;
		this.lir = lir;
		this.ir = ir;

		lir.storage = context.irBuffer.freePart.ptr;
		lir.storageLength = 0;
	}
}
