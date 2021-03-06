/**
Copyright: Copyright (c) 2017-2018 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module bench;

import all;
import tests;

void runBench()
{
	ModuleDeclNode* mod;
	Test curTest = test8;
	//Test curTest = test21;

	Driver driver;
	driver.initialize(compilerPasses);
	//driver.context.validateIr = true;
	scope(exit) driver.releaseMemory;

	enum iters = 100_000;
	auto times = PerPassTimeMeasurements(iters, driver.passes);

	foreach (iteration; 0..times.totalTimes.numIters)
	{
		auto time1 = currTime;
		mod = driver.compileModule(curTest.source, curTest.externalSymbols);
		auto time2 = currTime;

		times.onIteration(iteration, time2-time1);
	}

	times.print;
}
