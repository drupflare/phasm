/**
 * Park a Zend VM continuation so a synchronous PHP call can be answered by an asynchronous host.
 *
 * The mechanism, measured before this file existed (see the worker repo's TECHNICAL_REPORT):
 * `execute_data` and the VM stack are already heap-backed, so a `longjmp` out of `pib_run` destroys
 * every C frame and loses nothing Zend needs. Re-entering `execute_ex()` at the saved opline
 * resumes the chain with every layer's locals intact. Verified byte-identically on a native
 * interpreter and on a wasm one.
 *
 * WHAT CANNOT SURVIVE, and why the predicate exists: the C locals of an INTERNAL function that
 * called userland and is waiting to resume. `array_map`, `usort` and `iterator_to_array` are the
 * shapes; a park under one returns a silently wrong answer, so `park_refused()` walks
 * `prev_execute_data` to the host's own entry frame and a refused park falls through to the real
 * function instead. `call_user_func_array` is NOT such a frame, which is what makes Drupal's own
 * dispatch parkable.
 */

/* before php.h: a phpize build puts COMPILE_DL_CFWPARK here, and without it the ZEND_GET_MODULE at
 * the bottom is compiled out and the .so loads as "not a PHP library" */
#ifdef HAVE_CONFIG_H
	#include "config.h"
#endif

#include "php.h"
#include "zend_execute.h"
#include "zend_exceptions.h"
#include "ext/standard/info.h"
#include "php_streams.h"
#include <setjmp.h>

#define CFW_MAX_TRAPS 32

static jmp_buf park_jmp;
static int park_armed = 0;

/* the frame the host entered the VM at; the predicate stops there rather than walking to {main},
 * because counting the host's own entry refuses every park */
static zend_execute_data* park_floor = NULL;

static zend_execute_data* saved_call;
static zend_execute_data* saved_caller;
static const zend_op* saved_opline;
static zval* saved_ret;
static zend_execute_data* saved_root;

static int held = 0;
static zend_execute_data* held_call;
static zend_execute_data* held_caller;
static const zend_op* held_opline;
static zval* held_ret;
static zval* held_vm_stack_top;
static zval* held_vm_stack_end;
static zend_vm_stack held_vm_stack;
/**
 * The outermost frame of the parked chain, which is what a RESUMED chain stops the predicate on.
 *
 * `park_floor` cannot serve for a resume, and using it there was a crash rather than a wrong
 * answer. The floor is the frame the host entered the VM at, and a resume enters from a DIFFERENT
 * invocation
 * -- while `held_caller->prev_execute_data` still points at the chain the first `cfw_park_run`
 * built. So the walk never met the new floor: it went past the parked chain into the first
 * invocation's
 * `{main}`, whose frame had been popped and its VM stack slot reused, and followed
 * `prev_execute_data` through whatever now occupied that memory. Measured on the shipping wasm
 * build as `RuntimeError: memory access out of bounds`, and before that as a silent refusal --
 * because a nonzero count from garbage reads exactly like an unsafe park.
 *
 * Set once per chain, by `cfw_park_run`. A resume must NOT recompute it: with the floor already at
 * the root, the walk stops one frame short and would hand back a deeper frame each trip.
 */
static zend_execute_data* held_root;

/* what the host has to perform before the chain can be resumed */
static zend_string* pending_fn = NULL;
static zval pending_args;
static int pending_valid = 0;

typedef struct {
	zend_function* fn;
	void(ZEND_FASTCALL* original)(zend_execute_data*, zval*);
} cfw_trap;

static cfw_trap cfw_traps[CFW_MAX_TRAPS];
static int cfw_trap_count = 0;

static int park_refused(zend_execute_data* call) {
	/* the whole chain down to the floor, with no early break on ZEND_CALL_TOP: a closure invoked
	 * from C carries that flag, so breaking there reads safe for exactly the cases that corrupt */
	zend_execute_data* ex = call ? call->prev_execute_data : NULL;
	int unsafe = 0;
	while (ex && ex != park_floor) {
		if (ex->func && ex->func->type == ZEND_INTERNAL_FUNCTION) unsafe++;
		ex = ex->prev_execute_data;
	}
	return unsafe;
}

/**
 * The outermost frame between a trapped call and the floor; see {@link held_root}.
 *
 * Starts at `call` rather than at NULL so a park whose caller IS the floor answers its own frame.
 * That cannot happen through `cfw_park_run` -- the eval frame always sits between -- and a root
 * that defaults to the floor would hand a resume a stale pointer, which is the whole defect.
 */
static zend_execute_data* chain_root(zend_execute_data* call) {
	zend_execute_data* ex = call ? call->prev_execute_data : NULL;
	zend_execute_data* last = call;
	while (ex && ex != park_floor) {
		last = ex;
		ex = ex->prev_execute_data;
	}
	return last;
}

static void clear_pending(void) {
	if (pending_fn) {
		zend_string_release(pending_fn);
		pending_fn = NULL;
	}
	if (pending_valid) {
		zval_ptr_dtor(&pending_args);
		pending_valid = 0;
	}
}

/* copied off the call frame rather than referenced: the host reads this on a later invocation, and
 * the frame's own args are freed when the chain is resumed */
static void capture_pending(zend_execute_data* call) {
	clear_pending();
	pending_fn = zend_string_copy(call->func->common.function_name);
	array_init(&pending_args);
	uint32_t argc = ZEND_CALL_NUM_ARGS(call);
	for (uint32_t i = 0; i < argc; i++) {
		zval* arg = ZEND_CALL_ARG(call, i + 1);
		zval copy;
		ZVAL_COPY(&copy, arg);
		add_next_index_zval(&pending_args, &copy);
	}
	pending_valid = 1;
}

static cfw_trap* trap_for(const zend_function* fn) {
	for (int i = 0; i < cfw_trap_count; i++) {
		if (cfw_traps[i].fn == fn) return &cfw_traps[i];
	}
	return NULL;
}

/**
 * Stands in for a blocking call.
 *
 * A refused park calls the REAL function rather than throwing, so a site behaves exactly as it does
 * without this extension wherever the park cannot be taken. That keeps the failure mode additive:
 * the park is an improvement where it applies and invisible where it does not.
 */
static void ZEND_FASTCALL park_trap_handler(zend_execute_data* call, zval* ret) {
	cfw_trap* trap = trap_for(call->func);

	if (!park_armed || park_refused(call) > 0) {
		if (trap && trap->original) {
			trap->original(call, ret);
		}
		else {
			ZVAL_FALSE(ret);
		}
		return;
	}

	capture_pending(call);
	saved_call = call;
	saved_caller = call->prev_execute_data;
	saved_opline = saved_caller->opline;
	saved_ret = ret;
	/* while park_floor is still this chain's, which is the only point it can be computed from */
	saved_root = chain_root(call);
	longjmp(park_jmp, 1);
}

/** Installs the trap on one internal function; returns false when the name is not one. */
PHP_FUNCTION(cfw_park_trap) {
	zend_string* name;
	ZEND_PARSE_PARAMETERS_START(1, 1)
	Z_PARAM_STR(name)
	ZEND_PARSE_PARAMETERS_END();

	if (cfw_trap_count >= CFW_MAX_TRAPS) RETURN_FALSE;

	zend_string* lc = zend_string_tolower(name);
	zend_function* fn = zend_hash_find_ptr(CG(function_table), lc);
	zend_string_release(lc);
	if (!fn || fn->type != ZEND_INTERNAL_FUNCTION) RETURN_FALSE;
	if (trap_for(fn)) RETURN_TRUE;

	cfw_traps[cfw_trap_count].fn = fn;
	cfw_traps[cfw_trap_count].original = fn->internal_function.handler;
	cfw_trap_count++;
	fn->internal_function.handler = park_trap_handler;
	RETURN_TRUE;
}

/** How many internal frames a park at this point would lose; 0 means parkable. */
PHP_FUNCTION(cfw_park_safe) {
	ZEND_PARSE_PARAMETERS_NONE();
	RETURN_LONG(park_refused(EG(current_execute_data)));
}

/**
 * Runs one request. Answers `PARKED` when it stopped on a trapped call and `DONE` when it finished.
 *
 * The chain is born on its OWN VM stack page, before the body runs. Handing it a page at the park
 * instead takes the page out from under the host, because this function's own `return_value` is an
 * `EX_VAR` of its caller's frame. Swoole does the same thing per coroutine for the same reason.
 */
PHP_FUNCTION(cfw_park_run) {
	zend_string* code;
	ZEND_PARSE_PARAMETERS_START(1, 1)
	Z_PARAM_STR(code)
	ZEND_PARSE_PARAMETERS_END();

	if (held) {
		zend_throw_error(NULL, "cfw: a chain is already parked");
		RETURN_THROWS();
	}

	zend_execute_data* host_ced = EG(current_execute_data);
	JMP_BUF* outer_bailout = EG(bailout);

	zend_vm_stack host_stack = EG(vm_stack);
	zval* host_top = EG(vm_stack_top);
	zval* host_end = EG(vm_stack_end);
	/* php-src's own default page size; the macro is internal to zend_execute.c */
	zend_vm_stack own = zend_vm_stack_new_page(16 * 1024 * sizeof(zval), NULL);
	EG(vm_stack) = own;
	EG(vm_stack_top) = own->top;
	EG(vm_stack_end) = own->end;

	zend_execute_data* outer_floor = park_floor;
	park_floor = host_ced;
	int parked;
	if (setjmp(park_jmp) == 0) {
		park_armed = 1;
		zend_try {
			zend_eval_string(ZSTR_VAL(code), NULL, "cfw-request");
		}
		zend_end_try();
		park_armed = 0;
		parked = 0;
	}
	else {
		/* the longjmp jumped over zend_end_try(), so EG(bailout) is a dead frame */
		park_armed = 0;
		EG(bailout) = outer_bailout;
		parked = 1;
	}

	held_vm_stack = EG(vm_stack);
	held_vm_stack_top = EG(vm_stack_top);
	held_vm_stack_end = EG(vm_stack_end);
	EG(vm_stack) = host_stack;
	EG(vm_stack_top) = host_top;
	EG(vm_stack_end) = host_end;
	EG(current_execute_data) = host_ced;
	park_floor = outer_floor;

	if (!parked) {
		efree(held_vm_stack);
		clear_pending();
		RETURN_STRING("DONE");
	}

	held_call = saved_call;
	held_caller = saved_caller;
	held_opline = saved_opline;
	held_ret = saved_ret;
	/* the chain's root, recorded once here and never recomputed on a resume */
	held_root = saved_root;
	held = 1;
	RETURN_STRING("PARKED");
}

/** The operation the host must perform, or null when nothing is parked. */
PHP_FUNCTION(cfw_park_pending) {
	ZEND_PARSE_PARAMETERS_NONE();
	if (!held || !pending_valid) RETURN_NULL();

	array_init(return_value);
	add_assoc_str(return_value, "fn", zend_string_copy(pending_fn));
	zval args;
	ZVAL_COPY(&args, &pending_args);
	add_assoc_zval(return_value, "args", &args);
}

/**
 * Resumes the parked chain with the host's answer, from a separate VM entry.
 *
 * Answers `PARKED` again when the chain stops on a SECOND trapped call and `DONE` when it finishes,
 * so the host drives one uniform loop: run -> (pending -> perform -> resume)* -> DONE.
 *
 * **RE-ARMS, and the first version did not.** Without arming here `park_armed` is 0 for the whole
 * resume, so a multi-trip operation falls through to the real function on every trip after the
 * first -- which is silent, because a fall-through is the refusal path and looks deliberate. One
 * authenticated OIDC login is 3 trips, so only the first would have parked.
 */
PHP_FUNCTION(cfw_park_resume) {
	zval* answer;
	ZEND_PARSE_PARAMETERS_START(1, 1)
	Z_PARAM_ZVAL(answer)
	ZEND_PARSE_PARAMETERS_END();

	if (!held) {
		zend_throw_error(NULL, "cfw: nothing is parked");
		RETURN_THROWS();
	}
	held = 0;
	clear_pending();

	zend_execute_data* host_ced = EG(current_execute_data);
	JMP_BUF* outer_bailout = EG(bailout);
	zend_vm_stack host_stack = EG(vm_stack);
	zval* host_top = EG(vm_stack_top);
	zval* host_end = EG(vm_stack_end);

	EG(vm_stack) = held_vm_stack;
	EG(vm_stack_top) = held_vm_stack_top;
	EG(vm_stack_end) = held_vm_stack_end;

	ZVAL_COPY(held_ret, answer);

	uint32_t call_info = ZEND_CALL_INFO(held_call);
	zend_vm_stack_free_args(held_call);
	if (UNEXPECTED(call_info & ZEND_CALL_ALLOCATED)) {
		zend_vm_stack_free_call_frame_ex(call_info, held_call);
	}
	else {
		EG(vm_stack_top) = (zval*) held_call;
	}

	held_caller->opline = held_opline + 1;

	/**
	 * RELINK THE CHAIN'S ROOT TO THIS ENTRY, which is what a generator does and what this did not.
	 *
	 * `held_root->prev_execute_data` still named the frame that ran the original `cfw_park_run`,
	 * and that frame died with its invocation. Two things then went wrong at once: the predicate
	 * walked past the chain into reused VM stack memory, and the chain had no valid way to RETURN
	 * -- when its outermost frame completed, the VM followed that pointer into a dead parent.
	 *
	 * `zend_generator_resume` relinks `prev_execute_data` on every resume for exactly this reason.
	 * It is one assignment and it makes the floor correct again: the chain now genuinely hangs off
	 * this call, so `host_ced` is its ancestor and the walk terminates there.
	 *
	 * A flat harness hid it. Calling run and resume from the same scope puts the resume's frame in
	 * the slot the run's frame just vacated, so the stale pointer and the live one are the same
	 * ADDRESS and everything works by coincidence. Resuming from a different stack depth -- which
	 * is every Worker invocation -- segfaults without this.
	 */
	held_root->prev_execute_data = host_ced;
	zend_execute_data* outer_floor = park_floor;
	park_floor = host_ced;
	int parked;
	if (setjmp(park_jmp) == 0) {
		park_armed = 1;
		EG(current_execute_data) = held_caller;
		zend_try {
			execute_ex(held_caller);
		}
		zend_end_try();
		park_armed = 0;
		parked = 0;
	}
	else {
		park_armed = 0;
		EG(bailout) = outer_bailout;
		parked = 1;
	}

	held_vm_stack = EG(vm_stack);
	held_vm_stack_top = EG(vm_stack_top);
	held_vm_stack_end = EG(vm_stack_end);
	EG(current_execute_data) = host_ced;
	EG(vm_stack) = host_stack;
	EG(vm_stack_top) = host_top;
	EG(vm_stack_end) = host_end;
	park_floor = outer_floor;

	if (!parked) {
		efree(held_vm_stack);
		RETURN_STRING("DONE");
	}

	held_call = saved_call;
	held_caller = saved_caller;
	held_opline = saved_opline;
	held_ret = saved_ret;
	/* held_root is NOT reassigned: the chain's root does not move, and recomputing it here would
	 * read one frame short of it, since the floor is already sitting on it */
	held = 1;
	RETURN_STRING("PARKED");
}

/* hand-written rather than generated from a stub file: without arginfo the engine prints
 * "Missing arginfo for cfw_park_*" on every startup, which is five lines in every site's log */
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_cfw_park_trap, 0, 1, _IS_BOOL, 0)
ZEND_ARG_TYPE_INFO(0, name, IS_STRING, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_cfw_park_safe, 0, 0, IS_LONG, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_cfw_park_run, 0, 1, IS_STRING, 0)
ZEND_ARG_TYPE_INFO(0, code, IS_STRING, 0)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_cfw_park_pending, 0, 0, IS_ARRAY, 1)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_cfw_park_resume, 0, 1, IS_STRING, 0)
ZEND_ARG_TYPE_INFO(0, answer, IS_MIXED, 0)
ZEND_END_ARG_INFO()

static const zend_function_entry cfwpark_functions[] = {
	ZEND_FE(cfw_park_trap, arginfo_cfw_park_trap) ZEND_FE(cfw_park_safe, arginfo_cfw_park_safe)
		ZEND_FE(cfw_park_run, arginfo_cfw_park_run)
			ZEND_FE(cfw_park_pending, arginfo_cfw_park_pending)
				ZEND_FE(cfw_park_resume, arginfo_cfw_park_resume) ZEND_FE_END
};

zend_module_entry cfwpark_module_entry = {
	STANDARD_MODULE_HEADER,	   "cfwpark", cfwpark_functions, NULL, NULL, NULL, NULL, NULL, "0.1",
	STANDARD_MODULE_PROPERTIES
};

#ifdef COMPILE_DL_CFWPARK
ZEND_GET_MODULE(cfwpark)
#endif
