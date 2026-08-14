/*
 * Can a JSPI suspension cross a setjmp frame?
 *
 * This is the question that decides whether php-wasm can EVER slice a render,
 * because pib_run() opens a zend_try (= setjmp) before it calls into the VM
 * (source/pib/pib.c:196) and zend_eval_stringl() opens another one before it
 * calls zend_execute() (Zend/zend_execute_API.c). With emscripten's default
 * SjLj those calls are rewritten into invoke_* trampolines, which are JS
 * functions -- and JSPI refuses to suspend a stack with a JS frame on it.
 * vendor/static-o2/php8.3-worker.mjs contains 35 invoke_* references, so this is
 * not hypothetical for the shipping build.
 *
 * -sSUPPORT_LONGJMP=wasm is the candidate fix: longjmp goes through wasm
 * exception handling instead, so no JS frame is introduced. This probe is the
 * cheap way to test that claim without a 40-minute PHP build: the same C, linked
 * twice, run in workerd both ways.
 *
 * Built by src/build-sjlj-probe.sh.
 */
#include <setjmp.h>
#include <emscripten/emscripten.h>
#include <emscripten/em_js.h>

EM_ASYNC_JS(int, cfw_yield, (int seq), {
	var f = globalThis["cfwYield"];
	if (!f) {
		return 0;
	}
	var r = await f(seq);
	return r | 0;
});

static volatile int acc = 0;

/* the frame that suspends, two calls below the setjmp */
__attribute__((noinline)) static int deep(int i) {
	volatile int marker = 0x5A5A5A5A;
	acc += i;
	int r = cfw_yield(i);
	return (marker == 0x5A5A5A5A ? 0 : 1) + r + acc;
}

__attribute__((noinline)) static int middle(int i) {
	volatile int marker2 = 0x1234ABCD;
	return deep(i) + (marker2 == 0x1234ABCD ? 0 : 2);
}

/* the setjmp frame; under emscripten SjLj its calls become invoke_* (JS) */
int EMSCRIPTEN_KEEPALIVE run_with_setjmp(int i) {
	jmp_buf jb;
	if (setjmp(jb) != 0) {
		return -1;
	}
	return middle(i);
}

/* control: identical path with no setjmp anywhere */
int EMSCRIPTEN_KEEPALIVE run_plain(int i) {
	return middle(i);
}

int EMSCRIPTEN_KEEPALIVE acc_value(void) {
	return acc;
}

int main(void) {
	return 0;
}
