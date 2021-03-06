/**
Copyright: Copyright (c) 2017-2018 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
/// IR Function
module ir.ir_function;

import std.string : format;

import all;
import ir.ir_index;

/// Allows associating a single uint sized item with any object in original IR
/// IR must be immutable (no new items must added)
/// Mirror is stored in temp memory of context
struct IrMirror(T)
{
	static assert(T.sizeof == uint.sizeof, "T size must be equal to uint.sizeof");

	// Mirror of original IR
	private uint[] irMirror;

	void create(CompilationContext* context, IrFunction* ir)
	{
		irMirror = context.tempBuffer.voidPut(ir.storageLength);
		irMirror[] = 0;
	}

	ref T opIndex(IrIndex irIndex)
	{
		return *cast(T*)&irMirror[irIndex.storageUintIndex];
	}
}

struct IrFunction
{
	uint* storage;
	/// number of uints allocated from storage
	uint storageLength;

	/// Special block. Automatically created. Program start. Created first.
	IrIndex entryBasicBlock;
	/// Special block. Automatically created. All returns must jump to it.
	IrIndex exitBasicBlock;
	// The last created basic block
	IrIndex lastBasicBlock;
	///
	uint numBasicBlocks;

	/// First virtual register in linked list
	IrIndex firstVirtualReg;
	/// Last virtual register in linked list
	IrIndex lastVirtualReg;
	/// Total number of virtual registers
	uint numVirtualRegisters;

	VregIterator virtualRegsiters() { return VregIterator(&this); }

	///
	IrValueType returnType;
	///
	Identifier name;
	///
	CallConv* callingConvention;

	BlockIterator blocks() { return BlockIterator(&this); }
	BlockReverseIterator blocksReverse() { return BlockReverseIterator(&this); }

	alias getBlock = get!IrBasicBlock;
	alias getPhi = get!IrPhi;
	alias getVirtReg = get!IrVirtualRegister;

	ref T get(T)(IrIndex index)
	{
		assert(index.kind != IrValueKind.none, "null index");
		assert(index.kind == getIrValueKind!T, format("%s != %s", index.kind, getIrValueKind!T));
		return *cast(T*)(&storage[index.storageUintIndex]);
	}

	void assignSequentialBlockIndices()
	{
		uint index;
		foreach (idx, ref IrBasicBlock block; blocks)
		{
			block.seqIndex = index++;
		}
	}
}

// instruction iterators are aware of this
// only safe to delete current instruction while iterating
void removeInstruction(ref IrFunction ir, IrIndex instrIndex)
{
	IrInstrHeader* instrHeader = &ir.get!IrInstrHeader(instrIndex);

	if (instrHeader.prevInstr.isInstruction)
		ir.get!IrInstrHeader(instrHeader.prevInstr).nextInstr = instrHeader.nextInstr;
	else if (instrHeader.prevInstr.isBasicBlock)
		ir.getBlock(instrHeader.prevInstr).firstInstr = instrHeader.nextInstr;

	if (instrHeader.nextInstr.isInstruction)
		ir.get!IrInstrHeader(instrHeader.nextInstr).prevInstr = instrHeader.prevInstr;
	else if (instrHeader.nextInstr.isBasicBlock)
		ir.getBlock(instrHeader.nextInstr).lastInstr = instrHeader.prevInstr;
}

void removeUser(ref IrFunction ir, IrIndex user, IrIndex used) {
	assert(used.isDefined, "used is undefined");
	final switch (used.kind) with(IrValueKind) {
		case none: assert(false, "removeUser none");
		case listItem: assert(false, "removeUser listItem");
		case instruction: assert(false, "removeUser instruction");
		case basicBlock: break; // allowed. As argument of jmp jcc
		case constant: break; // allowed, noop
		case phi: assert(false, "removeUser phi"); // must be virt reg instead
		case memoryAddress: break; // allowed, noop
		case stackSlot: break; // allowed, noop
		case virtualRegister:
			ir.getVirtReg(used).users.remove(ir, user);
			break;
		case physicalRegister: break; // allowed, noop
	}
}

struct BlockIterator
{
	IrFunction* ir;
	int opApply(scope int delegate(IrIndex, ref IrBasicBlock) dg) {
		IrIndex next = ir.entryBasicBlock;
		while (next.isDefined)
		{
			IrBasicBlock* block = &ir.getBlock(next);
			if (int res = dg(next, *block))
				return res;
			next = block.nextBlock;
		}
		return 0;
	}
}

struct VregIterator
{
	IrFunction* ir;
	int opApply(scope int delegate(IrIndex, ref IrVirtualRegister) dg) {
		IrIndex next = ir.firstVirtualReg;
		while (next.isDefined)
		{
			IrVirtualRegister* vreg = &ir.getVirtReg(next);
			if (int res = dg(next, *vreg))
				return res;
			next = vreg.nextVirtReg;
		}
		return 0;
	}
}

struct BlockReverseIterator
{
	IrFunction* ir;
	int opApply(scope int delegate(IrIndex, ref IrBasicBlock) dg) {
		IrIndex prev = ir.exitBasicBlock;
		while (prev.isDefined)
		{
			IrBasicBlock* block = &ir.getBlock(prev);
			if (int res = dg(prev, *block))
				return res;
			prev = block.prevBlock;
		}
		return 0;
	}
}

void validateIrFunction(ref CompilationContext context, ref IrFunction ir)
{
	foreach (IrIndex blockIndex, ref IrBasicBlock block; ir.blocks)
	{
		if (!block.isSealed)
		{
			context.internal_error("Unsealed basic block %s", blockIndex);
		}

		if (!block.isFinished)
		{
			context.internal_error("Unfinished basic block %s", blockIndex);
		}

		// Check that all users of virtual reg point to definition
		void checkArg(IrIndex argUser, IrIndex arg)
		{
			if (!arg.isVirtReg) return;

			auto vreg = &ir.getVirtReg(arg);

			// How many times 'argUser' is found in vreg.users
			uint numVregUses = 0;
			foreach (i, IrIndex user; vreg.users.range(ir))
				if (user == argUser)
					++numVregUses;

			// How many times 'args' is found in instr.args
			uint timesUsed = 0;

			if (argUser.isInstruction)
			{
				foreach (i, IrIndex instrArg; ir.get!IrInstrHeader(argUser).args)
					if (instrArg == arg)
						++timesUsed;
			}
			else if (argUser.isPhi)
			{
				foreach(size_t arg_i, ref IrPhiArg phiArg; ir.getPhi(argUser).args(ir))
					if (phiArg.value == arg)
						++timesUsed;
			}
			else
			{
				context.internal_error("Virtual register cannot be used by %s", argUser.kind);
			}

			// For each use of arg by argUser there must one item in users list of vreg and in args list of user
			context.assertf(numVregUses == timesUsed,
				"Virtual register %s appears %s times as argument of %s, but instruction appears as user only %s times",
					arg, timesUsed, argUser, numVregUses);
		}

		void checkResult(IrIndex definition, IrIndex result)
		{
			auto vreg = &ir.getVirtReg(result);

			// Check that all users of virtual reg point to definition
			context.assertf(vreg.definition == definition,
				"Virtual register definition %s doesn't match instruction %s",
				vreg.definition, definition);

			foreach (i, IrIndex user; vreg.users.range(ir))
				checkArg(user, result);
		}

		foreach(IrIndex phiIndex, ref IrPhi phi; block.phis(ir))
		{
			size_t numPhiArgs = 0;
			foreach(size_t arg_i, ref IrPhiArg phiArg; phi.args(ir))
			{
				++numPhiArgs;
				checkArg(phiIndex, phiArg.value);
			}

			// check that phi-function receives values from all predecessors
			size_t numPredecessors = 0;
			foreach(IrIndex predIndex; block.predecessors.range(ir))
			{
				++numPredecessors;
			}

			context.assertf(numPhiArgs == numPredecessors,
				"Number of predecessors: %s doesn't match number of phi arguments: %s",
				numPredecessors, numPhiArgs);

			checkResult(phiIndex, phi.result);
			//writefln("phi %s args %s preds %s", phiIndex, numPhiArgs, numPredecessors);
		}

		foreach(IrIndex instrIndex, ref IrInstrHeader instrHeader; block.instructions(ir))
		{
			foreach (i, IrIndex arg; instrHeader.args)
			{
				checkArg(instrIndex, arg);
			}

			if (instrHeader.hasResult)
			{
				if (instrHeader.result.isVirtReg)
				{
					checkResult(instrIndex, instrHeader.result);
				}
			}
		}
	}
}
