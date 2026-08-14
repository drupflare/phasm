/*
 * Does a JSPI-suspended wasm stack survive the gap between two Durable Object
 * invocation callbacks?
 *
 * That is half (b) of the slicing question. Half (a) -- CPU attribution follows the
 * RESUMING invocation -- is already measured in plain JS (src/attribution-probe.js).
 * This half needs a wasm stack, and deliberately NOT php-wasm: a trivial C loop
 * isolates the platform question from every PHP question.
 *
 * The stack is what is under test, so every piece of loop state that has to survive
 * lives on the C stack, address-taken and volatile so the compiler cannot promote it
 * to a wasm global (which is linear-memory-adjacent state that would survive
 * trivially and prove nothing).
 *
 * cfw_mark() is called once per iteration and is NOT suspending, so the host can
 * record WHICH invocation each iteration ran in. That is the decisive evidence:
 * iterations up to park_at must be attributed to /park and the rest to /resume.
 *
 * Built by src/build-jspi-probe.sh with clang --target=wasm32 -nostdlib, so
 * there is no emscripten runtime in the picture and the JSPI wrapping is done with
 * the raw WebAssembly.Suspending / WebAssembly.promising API in src/jspi-probe.js.
 */

__attribute__((import_module("cfw"), import_name("park"))) extern int cfw_park(int iteration);

__attribute__((import_module("cfw"), import_name("mark"))) extern void cfw_mark(int iteration);

/* iteration-counted burn; a clock-driven one never terminates because Workers
   freeze Date.now() during synchronous execution */
__attribute__((noinline)) static double burn(int units) {
	double s = 0;
	const int n = units * 100000;
	for (int k = 0; k < n; k++) {
		s += __builtin_sqrt((double) (k % 1024)) * 1.0000001;
	}
	return s;
}

/* the frame that actually suspends, two levels below the promising export */
__attribute__((noinline)) static int inner(volatile int* acc, int i, int park_at, int units) {
	volatile int marker = 0x5A5A5A5A;
	volatile int local = i * 3;
	cfw_mark(i);
	*acc += (int) burn(units);
	if (i == park_at) {
		/* suspends here; the C stack holding marker, local and *acc must come back */
		local += cfw_park(i);
	}
	*acc += local;
	return marker == 0x5A5A5A5A ? 0 : 1;
}

__attribute__((noinline)) static int middle(volatile int* acc, int i, int park_at, int units) {
	volatile int marker2 = 0x1234ABCD;
	int bad = inner(acc, i, park_at, units);
	return bad + (marker2 == 0x1234ABCD ? 0 : 2);
}

/*
 * Returns acc * 1000 + a corruption bitmask, so one integer carries both the
 * arithmetic result and whether any stack slot came back wrong.
 *
 * bit 0: inner's marker corrupted
 * bit 1: middle's marker corrupted
 * bit 2: run_loop's own marker corrupted
 * bit 3: the loop did not complete every iteration
 */
__attribute__((visibility("default"))) int run_loop(int total, int park_at, int units) {
	volatile int acc = 0;
	volatile int marker3 = 0x0BADF00D;
	int corrupt = 0;
	int visited = 0;
	for (int i = 0; i < total; i++) {
		corrupt |= middle(&acc, i, park_at, units);
		visited++;
	}
	if (marker3 != 0x0BADF00D) corrupt |= 4;
	if (visited != total) corrupt |= 8;
	return acc * 1000 + corrupt;
}

/* control: the same total work with no suspension at all */
__attribute__((visibility("default"))) int run_loop_nopark(int total, int units) {
	return run_loop(total, -1, units);
}

__attribute__((noinline)) static int inner_multi(volatile int* acc, int i, int every, int units) {
	volatile int marker = 0x5A5A5A5A;
	volatile int local = i * 3;
	cfw_mark(i);
	*acc += (int) burn(units);
	/* suspends repeatedly on the SAME stack, which is what an N-slice render needs */
	if (every > 0 && i > 0 && i % every == 0) {
		local += cfw_park(i);
	}
	*acc += local;
	return marker == 0x5A5A5A5A ? 0 : 1;
}

/*
 * The production shape: one stack suspended and resumed N times, so a single
 * logical unit of work is spread over N separately-charged invocations.
 */
__attribute__((visibility("default"))) int run_loop_multi(int total, int every, int units) {
	volatile int acc = 0;
	volatile int marker3 = 0x0BADF00D;
	int corrupt = 0;
	int visited = 0;
	for (int i = 0; i < total; i++) {
		corrupt |= inner_multi(&acc, i, every, units);
		visited++;
	}
	if (marker3 != 0x0BADF00D) corrupt |= 4;
	if (visited != total) corrupt |= 8;
	return acc * 1000 + corrupt;
}
