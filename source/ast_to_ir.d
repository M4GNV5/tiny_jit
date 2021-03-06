/**
Copyright: Copyright (c) 2017-2018 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module ast_to_ir;

import std.stdio;
import all;


void pass_ir_gen(ref CompilationContext ctx) {
	auto astToIr = AstToIr(&ctx);
	astToIr.visit(ctx.mod);
}

//version = IrGenPrint;
//version = CfgGenPrint;

/// Converts AST to in-memory linear IR
struct AstToIr
{
	void visitType(TypeNode* n) {
		context.assertf(n.isType, n.loc, "Expected type, not %s", n.astType);
		switch(n.astType) with(AstType)
		{
			case type_basic: auto t = cast(BasicTypeNode*)n; visit(t); break;
			case type_ptr: auto t = cast(PtrTypeNode*)n; visit(t); break;
			case type_static_array: auto t = cast(StaticArrayTypeNode*)n; visit(t); break;
			case type_user: auto t = cast(UserTypeNode*)n; visit(t); break;

			default: context.unreachable(); assert(false);
		}
	}
	void visitExprValue(ExpressionNode* n, IrIndex currentBlock, ref IrLabel nextStmt) {
		context.assertf(n.isExpression, n.loc, "Expected expression, not %s", n.astType);
		switch(n.astType) with(AstType)
		{
			case expr_var: visitExprValue(cast(VariableExprNode*)n, currentBlock, nextStmt); break;
			case expr_literal: visitExprValue(cast(LiteralExprNode*)n, currentBlock, nextStmt); break;
			case expr_bin_op: visitExprValue(cast(BinaryExprNode*)n, currentBlock, nextStmt); break;
			case expr_call: visitExprValue(cast(CallExprNode*)n, currentBlock, nextStmt); break;
			case expr_index: visitExprValue(cast(IndexExprNode*)n, currentBlock, nextStmt); break;
			case expr_type_conv: visitExprValue(cast(TypeConvExprNode*)n, currentBlock, nextStmt); break;

			default: context.unreachable(); assert(false);
		}
	}
	void visitExprBranch(ExpressionNode* n, IrIndex currentBlock, ref IrLabel trueExit, ref IrLabel falseExit) {
		context.assertf(n.isExpression, n.loc, "Expected expression, not %s", n.astType);
		switch(n.astType) with(AstType)
		{
			case expr_var, expr_literal, expr_call, expr_index:
				context.internal_error("Trying to branch directly on %s, must be wrapped in convertion to bool", n.astType);
				break;

			case expr_bin_op: auto b = cast(BinaryExprNode*)n; visitExprBranch(b, currentBlock, trueExit, falseExit); break;
			case expr_type_conv: auto t = cast(TypeConvExprNode*)n; visitExprBranch(t, currentBlock, trueExit, falseExit); break;

			default: context.unreachable(); assert(false);
		}
	}
	void visitDecl(AstNode* n, IrIndex currentBlock, ref IrLabel nextStmt) {
		context.assertf(n.isDeclaration, n.loc, "Expected declaration, not %s", n.astType);
		switch(n.astType) with(AstType)
		{
			case decl_function, decl_struct:
				// skip
				if (currentBlock.isDefined)
					builder.addJumpToLabel(currentBlock, nextStmt);
				break;

			case decl_var: auto v = cast(VariableDeclNode*)n; visit(v, currentBlock, nextStmt); break;

			default: context.unreachable(); assert(false);
		}
	}
	void visitStmt(AstNode* n, IrIndex currentBlock, ref IrLabel nextStmt) {
		if (n.isDeclaration) {
			visitDecl(n, currentBlock, nextStmt);
			return;
		} else if (n.isExpression) {
			visitExprValue(cast(ExpressionNode*)n, currentBlock, nextStmt);
			return;
		}

		context.assertf(n.isStatement, n.loc, "Expected statement, not %s", n.astType);
		switch(n.astType) with(AstType)
		{
			case stmt_block: visit(cast(BlockStmtNode*)n, currentBlock, nextStmt); break;
			case stmt_if: visit(cast(IfStmtNode*)n, currentBlock, nextStmt); break;
			case stmt_while: visit(cast(WhileStmtNode*)n, currentBlock, nextStmt); break;
			case stmt_do_while: visit(cast(DoWhileStmtNode*)n, currentBlock, nextStmt); break;
			case stmt_return: visit(cast(ReturnStmtNode*)n, currentBlock, nextStmt); break;
			case stmt_break: visit(cast(BreakStmtNode*)n, currentBlock, nextStmt); break;
			case stmt_continue: visit(cast(ContinueStmtNode*)n, currentBlock, nextStmt); break;
			case stmt_assign: visit(cast(AssignStmtNode*)n, currentBlock, nextStmt); break;

			default: context.unreachable(); assert(false);
		}
	}

	CompilationContext* context;

	Identifier tempId;
	Identifier startId;
	Identifier thenId;
	Identifier elseId;
	Identifier blkId;

	IrBuilder builder;
	IrFunction* ir;

	enum MAX_ARGS = 255;
	IrIndex[MAX_ARGS] argsBuf;

	IrLabel* currentLoopHeader;
	IrLabel* currentLoopEnd;

	void visit(ModuleDeclNode* m)
	{
		version(IrGenPrint) writeln("[IR GEN] module begin");

		tempId = context.idMap.getOrRegNoDup("__tmp");
		startId = context.idMap.getOrRegNoDup("start");
		thenId = context.idMap.getOrRegNoDup("then");
		elseId = context.idMap.getOrRegNoDup("else");
		blkId = context.idMap.getOrRegNoDup("blk");
		foreach (decl; m.functions) {
			visit(decl);
			// can be null if function is external
			if (decl.irData)
			{
				m.irModule.addFunction(decl.irData);
				if (context.validateIr) validateIrFunction(*context, *decl.irData);
			}
		}
		version(IrGenPrint) writeln("[IR GEN] module end");
	}

	void visit(FunctionDeclNode* f)
	{
		version(IrGenPrint) writefln("[IR GEN] function (%s) begin", f.loc);
		version(IrGenPrint) scope(success) writefln("[IR GEN] function (%s) end", f.loc);
		if (f.isExternal) // external function
		{
			ExternalSymbol* sym = f.id in context.externalSymbols;
			if (sym is null)
			{
				context.error(f.loc,
					"Unresolved external function %s", f.strId(context));
				return;
			}
			f.funcPtr = sym.ptr;
			// TODO: check that parameters match
			return;
		}

		// create new function
		ir = new IrFunction;
		f.irData = ir;
		ir.returnType = f.returnType.irType(context);
		ir.name = f.id;
		ir.callingConvention = f.callingConvention;

		version(IrGenPrint) writefln("[IR GEN] function 1");
		builder.begin(ir, context);

		version(IrGenPrint) writefln("[IR GEN] function parameters");
		foreach (i, param; f.parameters)
		{
			IrLabel dummy;
			visitDecl(cast(AstNode*)param, ir.entryBasicBlock, dummy);
		}

		builder.addJump(ir.entryBasicBlock);

		IrIndex body_block = builder.addBasicBlock();
		builder.addBlockTarget(ir.entryBasicBlock, body_block);
		builder.sealBlock(body_block);

		// label at the end of body
		IrLabel bodyExitLabel = IrLabel(body_block);

		version(IrGenPrint) writefln("[IR GEN] function body");
		// compile body
		visitStmt(cast(AstNode*)f.block_stmt, body_block, bodyExitLabel);

		IrIndex currentBlock = bodyExitLabel.blockIndex;
		// In case new block was created, no new predecessors will be added
		builder.sealBlock(currentBlock);

		//writefln("cur block %s finished %s", currentBlock, ir.getBlock(currentBlock).isFinished);
		//writefln("end reached %s", bodyExitLabel.numPredecessors != 0);

		version(IrGenPrint) writefln("[IR GEN] function return");
		if (ir.returnType != IrValueType.void_t)
		{
			// currentBlock must be finished with retVal
			if (!ir.getBlock(currentBlock).isFinished)
			{
				context.error(f.loc,
					"function `%s` has no return statement, but is expected to return a value of type %s",
					context.idString(f.id), f.returnType.typeName(context));
			}
		}
		else
		{
			// currentBlock must be finished with ret or, not finished
			if (!ir.getBlock(currentBlock).isFinished)
			{
				builder.addReturn(currentBlock);
			}
		}

		version(IrGenPrint) writefln("[IR GEN] function seal exit");
		//dumpFunction_ir(*ir, *context);

		// all blocks with return (exit's predecessors) already connected, seal exit block
		builder.sealBlock(ir.exitBasicBlock);
	}

	void store(IrIndex currentBlock, VariableDeclNode* v, IrIndex value)
	{
		//if (v.forceMemoryStorage)
		//{
		//	builder.addInstruction!IrInstr_store(currentBlock);
		//	builder.emitInstr2(IrOpcode.o_store, v.type.irType(context), v.stackSlotId, value);
		//}
		//else
		//{
			version(IrGenPrint) writefln("[IR GEN] store %s to '%s'",
				value, context.idString(v.irVar.name));
			builder.writeVariable(currentBlock, v.irVar, value);
		//}
	}

	IrIndex load(IrIndex currentBlock, VariableDeclNode* v)
	{
		//if (v.forceMemoryStorage)
		//{
		//	return builder.emitInstr1(IrOpcode.o_load, v.type.irType(context), v.stackSlotId);
		//}
		//else
		//{
			auto result = builder.readVariable(currentBlock, v.irVar);
			version(IrGenPrint) writefln("[IR GEN] load %s from '%s'",
				result, context.idString(v.irVar.name));
			return result;
		//}
	}

	void visit(VariableDeclNode* v, IrIndex currentBlock, ref IrLabel nextStmt)
	{
		version(CfgGenPrint) writefln("[CFG GEN] beg VAR_DECL cur %s next %s", currentBlock, nextStmt);
		version(CfgGenPrint) scope(success) writefln("[CFG GEN] end VAR_DECL cur %s next %s", currentBlock, nextStmt);
		version(IrGenPrint) writefln("[IR GEN] Var decl (%s) begin %s", v.loc, v.strId(context));
		version(IrGenPrint) scope(success) writefln("[IR GEN] Var decl (%s) end %s", v.loc, v.strId(context));
		v.irVar = IrVar(v.id, builder.newIrVarId());//, v.type.irType(context));

		//if (context.buildDebug)
		//	v.varFlags |= VariableFlags.forceMemoryStorage;

		// Allocate stack slot for parameter that is passed via stack
		//bool isParamWithSlot = v.isParameter && ir.callingConvention.isParamOnStack(v.paramIndex);
		//bool needsStackSlot = v.forceMemoryStorage || isParamWithSlot;

		//if (needsStackSlot)
		//{
		//	v.stackSlotId = ir.stackLayout.addStackItem(v.type.size, v.type.alignment, v.isParameter, v.paramIndex);
		//}

		if (v.isParameter)
		{
			//++ir.numParameters;
			InstrWithResult param = builder.emitInstr!IrInstr_parameter(ir.entryBasicBlock);
			ir.get!IrInstr_parameter(param.instruction).index = v.paramIndex;
			//instr.stackSlot = v.stackSlotId;

			builder.writeVariable(currentBlock, v.irVar, param.result);
		}
		else
		{
			IrIndex value;
			if (v.initializer)
			{
				IrLabel afterExpr = IrLabel(currentBlock);
				visitExprValue(v.initializer, currentBlock, afterExpr);
				value = v.initializer.irRef;
				currentBlock = afterExpr.blockIndex;
			}
			else
				value = context.addConstant(IrConstant(0));
			store(currentBlock, v, value);
		}
		builder.addJumpToLabel(currentBlock, nextStmt);
	}
	void visit(StructDeclNode* s)
	{
		// skip
	}
	void visit(BlockStmtNode* b, IrIndex currentBlock, ref IrLabel nextStmt)
	{
		version(CfgGenPrint) writefln("[CFG GEN] beg BLOCK cur %s next %s", currentBlock, nextStmt);
		version(CfgGenPrint) scope(success) writefln("[CFG GEN] end BLOCK cur %s next %s", currentBlock, nextStmt);
		version(IrGenPrint) writefln("[IR GEN] block (%s) begin", b.loc);
		version(IrGenPrint) scope(success) writefln("[IR GEN] block (%s) end", b.loc);
		foreach (i, AstNode* stmt; b.statements)
		{
			version(IrGenPrint) writefln("[IR GEN]   stmt %s/%s", i+1, b.statements.length);
			// if not the last statement of block
			if (i < b.statements.length - 1)
			{
				// nested statement will jump here at its end
				IrLabel afterStmt = IrLabel(currentBlock);
				version(CfgGenPrint) writefln("[CFG GEN] beg cur %s afterStmt %s", currentBlock, afterStmt);

				// compile nested statement
				visitStmt(stmt, currentBlock, afterStmt);

				if (afterStmt.numPredecessors == 0)
				{
					version(IrGenPrint) writefln("[IR GEN]   no returns from stmt %s/%s, skipping the rest", i+1, b.statements.length);
					// Nested statement never returns here
					// Skip the rest of block statements
					return;
				}

				// If statement returned, get the new current block,
				// as it could have splitted the CFG and created a new block
				currentBlock = afterStmt.blockIndex;
				// Also seal it, since no other block can jump here
				builder.sealBlock(currentBlock);
				version(CfgGenPrint) writefln("[CFG GEN] end cur %s afterStmt %s", currentBlock, afterStmt);
			}
			else // last statement
			{
				version(CfgGenPrint) writefln("[CFG GEN] beg last cur %s next %s", currentBlock, nextStmt);
				// let last statement exit straight to outer scope
				visitStmt(stmt, currentBlock, nextStmt);
				version(CfgGenPrint) writefln("[CFG GEN] end last cur %s next %s", currentBlock, nextStmt);

				// if statement hasn't returned here, let outer scope handle this
				// the body exit is handled by function decl code
			}
		}

		if (b.statements.length == 0)
			builder.addJumpToLabel(currentBlock, nextStmt);
	}

	void visit(IfStmtNode* i, IrIndex currentBlock, ref IrLabel nextStmt)
	{
		version(CfgGenPrint) writefln("[CFG GEN] beg IF cur %s next %s", currentBlock, nextStmt);
		version(CfgGenPrint) scope(success) writefln("[CFG GEN] end IF cur %s next %s", currentBlock, nextStmt);
		if (i.elseStatement) // if then else
		{
			version(IrGenPrint) writefln("[IR GEN] if-else (%s) begin", i.loc);
			version(IrGenPrint) scope(success) writefln("[IR GEN] if-else (%s) end", i.loc);
			IrLabel trueLabel = IrLabel(currentBlock);
			IrLabel falseLabel = IrLabel(currentBlock);
			version(CfgGenPrint) writefln("[CFG GEN] before cond expr: true %s false %s", trueLabel, falseLabel);
			visitExprBranch(i.condition, currentBlock, trueLabel, falseLabel);
			version(CfgGenPrint) writefln("[CFG GEN] after cond expr: true %s false %s", trueLabel, falseLabel);

			if (trueLabel.numPredecessors != 0)
			{
				IrIndex thenBlock = trueLabel.blockIndex;
				builder.sealBlock(thenBlock);
				visitStmt(i.thenStatement, thenBlock, nextStmt);
			}
			else
				version(IrGenPrint) writeln("[IR GEN]   skip then stmt. Condition didn't jump here");
			version(CfgGenPrint) writefln("[CFG GEN] after true stmt: true %s false %s", trueLabel, falseLabel);

			if (falseLabel.numPredecessors != 0)
			{
				IrIndex elseBlock = falseLabel.blockIndex;
				builder.sealBlock(elseBlock);
				visitStmt(i.elseStatement, elseBlock, nextStmt);
			}
			else
				version(IrGenPrint) writeln("[IR GEN]   skip else stmt. Condition didn't jump here");
			version(CfgGenPrint) writefln("[CFG GEN] after false stmt: true %s false %s", trueLabel, falseLabel);
		}
		else // if then
		{
			version(IrGenPrint) writefln("[IR GEN] if (%s) begin", i.loc);
			version(IrGenPrint) scope(success) writefln("[IR GEN] if (%s) end", i.loc);
			IrLabel trueLabel = IrLabel(currentBlock);
			version(CfgGenPrint) writefln("[CFG GEN] before cond expr: true %s next %s", trueLabel, nextStmt);
			visitExprBranch(i.condition, currentBlock, trueLabel, nextStmt);
			version(CfgGenPrint) writefln("[CFG GEN] after cond expr: true %s next %s", trueLabel, nextStmt);

			if (trueLabel.numPredecessors != 0)
			{
				IrIndex thenBlock = trueLabel.blockIndex;
				builder.sealBlock(thenBlock);
				visitStmt(i.thenStatement, thenBlock, nextStmt);
			}
			else
				version(IrGenPrint) writeln("[IR GEN]   skip then stmt. Condition didn't jump here");
			version(CfgGenPrint) writefln("[CFG GEN] after true stmt: true %s next %s", trueLabel, nextStmt);
		}
	}
	void visit(WhileStmtNode* w, IrIndex currentBlock, ref IrLabel nextStmt) {
		version(CfgGenPrint) writefln("[CFG GEN] beg WHILE cur %s next %s", currentBlock, nextStmt);
		version(CfgGenPrint) scope(success) writefln("[CFG GEN] end WHILE cur %s next %s", currentBlock, nextStmt);
		//writefln("loop cur 1 %s", currentBlock);
		// loop header
		IrLabel loopHeaderLabel = IrLabel(currentBlock);

		IrLabel* prevLoopHeader = currentLoopHeader; // save
		currentLoopHeader = &loopHeaderLabel;
		scope(exit) currentLoopHeader = prevLoopHeader; // restore
		IrLabel* prevLoopEnd = currentLoopEnd; // save
		currentLoopEnd = &nextStmt;
		scope(exit) currentLoopEnd = prevLoopEnd; // restore

		builder.addJumpToLabel(currentBlock, loopHeaderLabel);

		// we need loop header in a separate block because it will
		// have 2 predecessors: currentBlock and loop body
		builder.forceAllocLabelBlock(loopHeaderLabel);
		IrIndex loopHeaderBlock = loopHeaderLabel.blockIndex;
		//writefln("loop head %s", loopHeaderBlock);
		ir.getBlock(loopHeaderBlock).isLoopHeader = true;

		IrLabel bodyLabel = IrLabel(currentBlock);
		builder.forceAllocLabelBlock(bodyLabel);
		//writefln("loop body %s, next %s", bodyLabel.blockIndex, nextStmt.blockIndex);

		// will force allocate body block
		visitExprBranch(w.condition, loopHeaderBlock, bodyLabel, nextStmt);

		currentBlock = bodyLabel.blockIndex;
		//writefln("loop body %s, next %s", bodyLabel.blockIndex, nextStmt.blockIndex);
		builder.sealBlock(currentBlock);

		// body
		IrBasicBlock* block = &ir.getBlock(currentBlock);
		assert(!block.isFinished);
		visitStmt(w.statement, currentBlock, loopHeaderLabel);

		builder.sealBlock(loopHeaderBlock);
	}
	void visit(DoWhileStmtNode* d, IrIndex currentBlock, ref IrLabel nextStmt) {
		context.unreachable;
	}
	void visit(ReturnStmtNode* r, IrIndex currentBlock, ref IrLabel nextStmt)
	{
		version(CfgGenPrint) writefln("[CFG GEN] beg RETURN cur %s next %s", currentBlock, nextStmt);
		version(CfgGenPrint) scope(success) writefln("[CFG GEN] end RETURN cur %s next %s", currentBlock, nextStmt);
		version(IrGenPrint) writefln("[IR GEN] return (%s) begin", r.loc);
		version(IrGenPrint) scope(success) writefln("[IR GEN] return (%s) end", r.loc);
		if (r.expression)
		{
			IrLabel afterExpr = IrLabel(currentBlock);
			visitExprValue(r.expression, currentBlock, afterExpr);
			currentBlock = afterExpr.blockIndex;
			builder.addReturn(currentBlock, cast(IrIndex)r.expression.irRef);
		}
		else builder.addReturn(currentBlock);
	}
	void visit(BreakStmtNode* b, IrIndex currentBlock, ref IrLabel nextStmt) {
		if (currentLoopEnd is null) context.unrecoverable_error(b.loc, "break is not within the loop");
		builder.addJumpToLabel(currentBlock, *currentLoopEnd);
	}
	void visit(ContinueStmtNode* c, IrIndex currentBlock, ref IrLabel nextStmt) {
		if (currentLoopHeader is null) context.unrecoverable_error(c.loc, "continue is not within the loop");
		builder.addJumpToLabel(currentBlock, *currentLoopHeader);
	}
	void visit(AssignStmtNode* a, IrIndex currentBlock, ref IrLabel nextStmt)
	{
		version(CfgGenPrint) writefln("[CFG GEN] beg ASSIGN cur %s next %s", currentBlock, nextStmt);
		version(CfgGenPrint) scope(success) writefln("[CFG GEN] end ASSIGN cur %s next %s", currentBlock, nextStmt);
		version(IrGenPrint) writefln("[IR GEN] assign (%s) begin", a.loc);
		version(IrGenPrint) scope(success) writefln("[IR GEN] assign (%s) end", a.loc);
		IrLabel afterLeft = IrLabel(currentBlock);
		visitExprValue(a.left, currentBlock, afterLeft);
		currentBlock = afterLeft.blockIndex;
		IrLabel afterRight = IrLabel(currentBlock);
		visitExprValue(a.right, currentBlock, afterRight);
		currentBlock = afterRight.blockIndex;

		final switch (a.op)
		{
			case AssignOp.opAssign:
				auto varExpr = cast(VariableExprNode*)a.left;
				store(currentBlock, varExpr.getSym.varDecl, a.right.irRef);
				break;
			case AssignOp.opIndexAssign:
				auto indexExpr = cast(IndexExprNode*)a.left;
				builder.emitInstr!IrInstr_store(currentBlock, indexExpr.irRef, a.right.irRef);
				break;
		}
		builder.addJumpToLabel(currentBlock, nextStmt);
	}

	void visitExprValue(VariableExprNode* v, IrIndex currentBlock, ref IrLabel nextStmt)
	{
		version(CfgGenPrint) writefln("[CFG GEN] beg VAR_USE VAL cur %s next %s", currentBlock, nextStmt);
		version(CfgGenPrint) scope(success) writefln("[CFG GEN] end VAR_USE VAL cur %s next %s", currentBlock, nextStmt);
		version(IrGenPrint) writefln("[IR GEN] var expr value (%s) begin", v.loc);
		version(IrGenPrint) scope(success) writefln("[IR GEN] var expr value (%s) end", v.loc);
		if (!v.isLvalue)
		{
			v.irRef = load(currentBlock, v.getSym.varDecl);
		}
		builder.addJumpToLabel(currentBlock, nextStmt);
	}
	void visitExprValue(LiteralExprNode* c, IrIndex currentBlock, ref IrLabel nextStmt)
	{
		version(CfgGenPrint) writefln("[CFG GEN] beg LITERAL VAL cur %s next %s", currentBlock, nextStmt);
		version(CfgGenPrint) scope(success) writefln("[CFG GEN] end LITERAL VAL cur %s next %s", currentBlock, nextStmt);
		version(IrGenPrint) writefln("[IR GEN] literal value (%s) value %s", c.loc, c.value);
		c.irRef = context.addConstant(IrConstant(c.value));
		builder.addJumpToLabel(currentBlock, nextStmt);
	}
	void placeUnaryBranch(IrIndex value, IrIndex currentBlock, ref IrLabel trueExit, ref IrLabel falseExit)
	{
		context.unreachable;
	}
	void placeBinaryBranch(BinOp op, IrIndex left, IrIndex right, IrIndex currentBlock, ref IrLabel trueExit, ref IrLabel falseExit)
	{
		context.unreachable;
	}

	long calcBinOp(BinOp op, long a, long b)
	{
		switch(op)
		{
			case BinOp.EQUAL_EQUAL:   return a == b;
			case BinOp.NOT_EQUAL:     return a != b;
			case BinOp.GREATER:       return a >  b;
			case BinOp.GREATER_EQUAL: return a >= b;
			case BinOp.LESS:          return a <  b;
			case BinOp.LESS_EQUAL:    return a <= b;
			case BinOp.PLUS:          return a +  b;
			case BinOp.MINUS:         return a -  b;
			default:
				context.internal_error("Opcode `%s` is not implemented", op);
				assert(false);
		}
	}

	static IrBinaryCondition convertBinOpToIrCond(BinOp op)
	{
		assert(op >= BinOp.EQUAL_EQUAL && op <= BinOp.LESS_EQUAL);
		return cast(IrBinaryCondition)(op - BinOp.EQUAL_EQUAL);
	}

	// In value mode only uses trueExit as nextStmt
	void visitBinOpImpl(bool forValue)(BinaryExprNode* b, ref IrIndex currentBlock, ref IrLabel trueExit, ref IrLabel falseExit)
	{
		IrLabel afterLeft = IrLabel(currentBlock);
		visitExprValue(b.left, currentBlock, afterLeft);
		currentBlock = afterLeft.blockIndex;
		version(CfgGenPrint) writefln("[CFG GEN] after left cur %s true %s false %s", currentBlock, trueExit, falseExit);
		IrLabel afterRight = IrLabel(currentBlock);
		visitExprValue(b.right, currentBlock, afterRight);
		currentBlock = afterRight.blockIndex;
		version(CfgGenPrint) writefln("[CFG GEN] after right cur %s true %s false %s", currentBlock, trueExit, falseExit);

		// constant folding
		if (b.left.irRef.isConstant && b.right.irRef.isConstant)
		{
			long arg0 = context.getConstant(cast(IrIndex)b.left.irRef).i64;
			long arg1 = context.getConstant(cast(IrIndex)b.right.irRef).i64;
			long value = calcBinOp(b.op, arg0, arg1);
			static if (forValue)
			{
				b.irRef = context.addConstant(IrConstant(value));
			}
			else
			{
				if (value)
					builder.addJumpToLabel(currentBlock, trueExit);
				else
					builder.addJumpToLabel(currentBlock, falseExit);
			}
			version(IrGenPrint) writefln("[IR GEN]   const expr %s", value);
			return;
		}

		auto lRef = b.left.irRef;
		auto rRef = b.right.irRef;

		static if (forValue)
		{
			switch(b.op) with(BinOp)
			{
				case EQUAL_EQUAL, NOT_EQUAL, GREATER, GREATER_EQUAL, LESS, LESS_EQUAL:
					version(IrGenPrint) writefln("[IR GEN]   rel op value %s", b.op);
					ExtraInstrArgs extra = {cond : convertBinOpToIrCond(b.op)};
					b.irRef = builder.emitInstr!IrInstr_set_binary_cond(
						currentBlock, extra, lRef, rRef).result;
					break;

				// TODO
				case PLUS: b.irRef = builder.emitInstr!IrInstr_add(currentBlock, lRef, rRef).result; break;
				case MINUS: b.irRef = builder.emitInstr!IrInstr_sub(currentBlock, lRef, rRef).result; break;

				default: context.internal_error(b.loc, "Opcode `%s` is not implemented", b.op); break;
			}
			builder.addJumpToLabel(currentBlock, trueExit);
		}
		else
		{
			switch(b.op) with(BinOp)
			{
				case EQUAL_EQUAL, NOT_EQUAL, GREATER, GREATER_EQUAL, LESS, LESS_EQUAL:
					version(IrGenPrint) writefln("[IR GEN]   rel op branch %s", b.op);
					auto branch = builder.addBinBranch(currentBlock, convertBinOpToIrCond(b.op), lRef, rRef, trueExit, falseExit);
					break;

				// TODO && || !
				default: context.internal_error(b.loc, "Opcode `%s` is not implemented", b.op); break;
			}
		}
	}

	void visitExprBranch(BinaryExprNode* b, IrIndex currentBlock, ref IrLabel trueExit, ref IrLabel falseExit)
	{
		version(CfgGenPrint) writefln("[CFG GEN] beg BINOP BR cur %s true %s false %s", currentBlock, trueExit, falseExit);
		version(CfgGenPrint) scope(success) writefln("[CFG GEN] end BINOP BR cur %s true %s false %s", currentBlock, trueExit, falseExit);
		version(IrGenPrint) writefln("[IR GEN] bin expr branch (%s) begin", b.loc);
		version(IrGenPrint) scope(success) writefln("[IR GEN] bin expr branch (%s) end", b.loc);
		visitBinOpImpl!false(b, currentBlock, trueExit, falseExit);
	}

	void visitExprValue(BinaryExprNode* b, IrIndex currentBlock, ref IrLabel nextStmt)
	{
		version(CfgGenPrint) writefln("[CFG GEN] beg BINOP VAL cur %s next %s", currentBlock, nextStmt);
		version(CfgGenPrint) scope(success) writefln("[CFG GEN] end BINOP VAL cur %s next %s", currentBlock, nextStmt);
		version(IrGenPrint) writefln("[IR GEN] bin expr value (%s) begin", b.loc);
		version(IrGenPrint) scope(success) writefln("[IR GEN] bin expr value (%s) end", b.loc);
		IrLabel fake;
		visitBinOpImpl!true(b, currentBlock, nextStmt, fake);
		assert(fake.numPredecessors == 0);
	}

	void visitExprValue(CallExprNode* c, IrIndex currentBlock, ref IrLabel nextStmt)
	{
		version(CfgGenPrint) writefln("[CFG GEN] beg CALL VAL cur %s next %s", currentBlock, nextStmt);
		version(CfgGenPrint) scope(success) writefln("[CFG GEN] end CALL VAL cur %s next %s", currentBlock, nextStmt);
		version(IrGenPrint) writefln("[IR GEN] call value (%s) begin", c.loc);
		version(IrGenPrint) scope(success) writefln("[IR GEN] call value (%s) end", c.loc);

		context.assertf(c.args.length <= MAX_ARGS,
			"Cannot generate a call with %s arguments, max args is %s",
			c.args.length, MAX_ARGS);

		foreach (i, ExpressionNode* arg; c.args) {
			IrLabel afterArg = IrLabel(currentBlock);
			visitExprValue(arg, currentBlock, afterArg);
			currentBlock = afterArg.blockIndex;
			argsBuf[i] = arg.irRef;
		}

		IrIndex[] args = argsBuf[0..c.args.length];
		FunctionDeclNode* callee = c.getSym.funcDecl;

		version(IrGenPrint) writefln("[IR GEN] call args %s, callee %s", args, callee.index);
		context.assertf(callee.index < context.mod.functions.length,
			"Callee index is out of bounds: index %s, num functions %s",
			callee.index, context.mod.functions.length);

		builder.emitInstrPreheader(IrInstrPreheader_call(callee.index));

		if (callee.returnType.isVoid) {
			InstrWithResult res = builder.emitInstr!IrInstr_call(currentBlock, args);
			context.assertf(!res.result.isDefined, "Call has result");
		} else {
			ExtraInstrArgs extra = {hasResult : true};
			InstrWithResult res = builder.emitInstr!IrInstr_call(currentBlock, extra, args);
			c.irRef = res.result;
		}

		builder.addJumpToLabel(currentBlock, nextStmt);
	}

	void visitExprValue(IndexExprNode* i, IrIndex currentBlock, ref IrLabel nextStmt)
	{
		version(CfgGenPrint) writefln("[CFG GEN] beg INDEX VAL cur %s next %s", currentBlock, nextStmt);
		version(CfgGenPrint) scope(success) writefln("[CFG GEN] end INDEX VAL cur %s next %s", currentBlock, nextStmt);
		IrLabel afterIndex = IrLabel(currentBlock);
		visitExprValue(i.array, currentBlock, afterIndex);
		currentBlock = afterIndex.blockIndex;

		IrLabel afterRight = IrLabel(currentBlock);
		visitExprValue(i.index, currentBlock, afterRight);
		currentBlock = afterRight.blockIndex;

		IrIndex address;
		if (i.index.irRef.isConstant)
		{
			ulong elemSize = i.type.size;
			ulong index = context.getConstant(i.index.irRef).i64;
			if (index == 0) {
				address = i.array.irRef;
			} else {
				IrIndex offset = context.addConstant(IrConstant(index * elemSize));
				address = builder.emitInstr!IrInstr_add(currentBlock, i.array.irRef, offset).result;
			}
		}
		else
		{
			IrIndex scale = context.addConstant(IrConstant(i.type.size));
			IrIndex offset = builder.emitInstr!IrInstr_mul(currentBlock, i.index.irRef, scale).result;
			address = builder.emitInstr!IrInstr_add(currentBlock, i.array.irRef, offset).result;
		}

		if (i.isLvalue) {
			i.irRef = address;
		} else {
			i.irRef = builder.emitInstr!IrInstr_load(currentBlock, address).result;
		}
		builder.addJumpToLabel(currentBlock, nextStmt);
	}

	void visitExprBranch(TypeConvExprNode* t, IrIndex currentBlock, ref IrLabel trueExit, ref IrLabel falseExit) {
		version(CfgGenPrint) writefln("[CFG GEN] beg TYPE_CONV BR cur %s true %s false %s", currentBlock, trueExit, falseExit);
		version(CfgGenPrint) scope(success) writefln("[CFG GEN] end TYPE_CONV BR cur %s true %s false %s", currentBlock, trueExit, falseExit);
		IrLabel afterExpr = IrLabel(currentBlock);
		visitExprValue(t.expr, currentBlock, afterExpr);
		currentBlock = afterExpr.blockIndex;

		IrValueType to = t.type.irType(context);
		IrValueType from = t.expr.type.irType(context);
		if (t.expr.irRef.isConstant)
		{
			long value = context.getConstant(cast(IrIndex)t.expr.irRef).i64;
			if (value != 0)
				builder.addJumpToLabel(currentBlock, trueExit);
			else
				builder.addJumpToLabel(currentBlock, falseExit);
			return;
		}
		else if (from == IrValueType.i32 || from == IrValueType.i64)
		{
			t.irRef = t.expr.irRef;
			builder.addUnaryBranch(currentBlock, IrUnaryCondition.not_zero, t.expr.irRef, trueExit, falseExit);
			return;
		}
		else
		{
			//t.irRef = builder.emitInstr1(IrOpcode.o_conv, to, t.expr.irRef);
			context.internal_error(t.loc, "%s to %s", t.expr.type.printer(context), t.type.printer(context));
		}
		context.unreachable;
	}
	void visitExprValue(TypeConvExprNode* t, IrIndex currentBlock, ref IrLabel nextStmt) {
		version(CfgGenPrint) writefln("[CFG GEN] beg TYPE_CONV VAL cur %s next %s", currentBlock, nextStmt);
		version(CfgGenPrint) scope(success) writefln("[CFG GEN] end TYPE_CONV VAL cur %s next %s", currentBlock, nextStmt);
		IrLabel afterExpr = IrLabel(currentBlock);
		visitExprValue(t.expr, currentBlock, afterExpr);
		currentBlock = afterExpr.blockIndex;

		IrValueType to = t.type.irType(context);
		IrValueType from = t.expr.type.irType(context);
		if (t.expr.irRef.isConstant || (from == IrValueType.i32 && to == IrValueType.i64))
		{
			t.irRef = t.expr.irRef;
		}
		else
		{
			//t.irRef = builder.emitInstr1(IrOpcode.o_conv, to, t.expr.irRef);
			context.internal_error(t.loc, "%s to %s", t.expr.type.printer(context), t.type.printer(context));
		}
		builder.addJumpToLabel(currentBlock, nextStmt);
	}
	void visit(BasicTypeNode* t) { context.unreachable; }
	void visit(PtrTypeNode* t) { context.unreachable; }
	void visit(StaticArrayTypeNode* t) { context.unreachable; }
	void visit(UserTypeNode* t) { context.unreachable; }
}
