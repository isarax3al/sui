// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Seed-and-mutate execute-after-verify fuzzer for the new arena/MemBox-based
//! Move VM.
//!
//! The bytecode verifier is what lets the interpreter skip runtime type and
//! reference checks: execution *trusts* that a loaded module is type- and
//! reference-safe. So the highest-severity VM bug is a **verifier/execution
//! mismatch** -- a module the verifier accepts but the interpreter mishandles.
//! On a validator that is a deterministic crash on a permissionlessly-published
//! module (chain halt), or, worse, a silent type confusion (memory unsafety ->
//! potential fund theft).
//!
//! Pure-random bytecode essentially never forms a stack-balanced, well-typed,
//! returning function, so it is rejected by the verifier before the interpreter
//! ever runs (measured: 0 of hundreds of thousands of random modules reached
//! execution). To actually exercise execution we instead **seed** from a real
//! compiled module whose no-arg `fun run()` performs arithmetic, a helper call,
//! a loop with a conditional branch, generic + non-generic struct pack/unpack,
//! mutable field borrow, and reference read/write -- guaranteed to verify and
//! execute -- and then apply a small `arbitrary`-driven **mutation** to its code
//! before running the real pipeline:
//!   serialize -> load (deserialize + full bytecode verifier + jit) -> execute.
//!
//! The unmutated seed always reaches execution (baseline coverage); most
//! mutations are rejected at load (fine, skipped); the fraction that remain
//! verifiable but semantically perturbed are exactly the verifier/execution
//! boundary we want to probe. A **panic** anywhere in the pipeline (caught
//! below) on a module that passed loading is a real verifier/execution-mismatch
//! candidate.
//!
//! Throughput note: each iteration builds a fresh runtime and JIT-compiles the
//! whole package, so this is a deliberately-thorough (not high-throughput)
//! harness -- on the order of a few iterations/second. `ITERATIONS` is sized for
//! a bounded local run; raise it for an overnight campaign, or reuse a single
//! runtime across iterations to trade isolation for speed.
//!
//! MUST be run with `--release --features "fuzzing testing"`: in debug builds
//! `safe_assert!`/`debug_assert!` inside the verifier and interpreter panic by
//! design (they return `Err` in release, which is what mainnet runs), so a debug
//! run reports those benign-in-production asserts as false positives. Only a
//! panic under `--release` indicates a real remote-crash candidate. Run with:
//! `cargo test --release --features "fuzzing testing" -p move-vm-runtime \
//!      fuzz_execute_no_panic -- --ignored --nocapture`

#![cfg(all(test, feature = "fuzzing"))]

use crate::{
    dev_utils::{
        compilation_utils::{as_module, compile_units},
        in_memory_test_adapter::InMemoryTestAdapter,
        storage::StoredPackage,
        vm_test_adapter::VMTestAdapter,
    },
    shared::gas::UnmeteredGasMeter,
};
use arbitrary::{Arbitrary, Unstructured};
use move_binary_format::file_format::{Bytecode, CompiledModule};
use move_core_types::account_address::AccountAddress;
use std::panic::{self, AssertUnwindSafe};

const TEST_ADDR: AccountAddress = AccountAddress::new([42; AccountAddress::LENGTH]);

/// Seed module source (self-contained: no external dependencies, so the single
/// file compiles on its own). `run()` is a no-arg public function exercising a
/// broad slice of the interpreter: integer arithmetic (with a helper call), a
/// loop with a conditional branch, generic + non-generic struct pack/unpack,
/// mutable field borrow, and reference read/write.
const SEED_SRC: &str = r#"
module 0x2a::M {
    public struct S has drop { x: u64, y: bool }
    public struct G<T> has drop { v: T }

    fun inc(a: u64): u64 { a + 1 }

    fun wrap<T>(t: T): G<T> { G { v: t } }

    public fun run() {
        let mut v: u64 = 0;
        let mut i: u64 = 0;
        while (i < 8) {
            if (i % 2 == 0) { v = v + inc(i) } else { v = v + i };
            i = i + 1;
        };
        let mut s = S { x: v, y: true };
        let r = &mut s.x;
        *r = *r + 1;
        let _read = *(&s.x);
        let g = wrap<u64>(s.x);
        let G { v: _gv } = g;
        let b = s.y && (v > 3);
        if (b) { s.x = s.x + 1 };
    }
}
"#;

/// Small deterministic xorshift PRNG so failures reproduce from the seed alone.
struct Rng(u64);
impl Rng {
    fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
}

/// A single `arbitrary`-driven edit to a function's instruction stream.
#[derive(Arbitrary, Debug)]
enum Mutation {
    /// Overwrite the instruction at `at % len` with an arbitrary bytecode.
    Replace { at: usize, instr: Bytecode },
    /// Insert an arbitrary bytecode before position `at % (len+1)`.
    Insert { at: usize, instr: Bytecode },
    /// Delete the instruction at `at % len`.
    Delete { at: usize },
    /// Swap the instructions at `a % len` and `b % len`.
    Swap { a: usize, b: usize },
}

fn compile_seed() -> CompiledModule {
    let mut units = compile_units(SEED_SRC).expect("seed source compiles");
    as_module(units.pop().unwrap())
}

/// Index of the `run` function definition within the module.
fn run_def_index(module: &CompiledModule) -> usize {
    module
        .function_defs
        .iter()
        .position(|fd| {
            let fh = &module.function_handles[fd.function.0 as usize];
            module.identifiers[fh.name.0 as usize].as_str() == "run"
        })
        .expect("seed has run()")
}

/// Apply one mutation to `run`'s code in place. No-op if the code is empty.
fn apply_mutation(module: &mut CompiledModule, run_idx: usize, m: Mutation) {
    let code = match &mut module.function_defs[run_idx].code {
        Some(cu) => &mut cu.code,
        None => return,
    };
    if code.is_empty() {
        return;
    }
    let len = code.len();
    match m {
        Mutation::Replace { at, instr } => code[at % len] = instr,
        Mutation::Insert { at, instr } => code.insert(at % (len + 1), instr),
        Mutation::Delete { at } => {
            code.remove(at % len);
        }
        Mutation::Swap { a, b } => code.swap(a % len, b % len),
    }
}

/// How far the mutated module got through the pipeline.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Reach {
    NotSerializable,
    LoadFailed,
    Executed,
}

fn publish_and_execute(module: CompiledModule) -> Reach {
    let module_id = module.self_id();
    let run_name = {
        let idx = run_def_index(&module);
        let fh = &module.function_handles[module.function_defs[idx].function.0 as usize];
        module.identifiers[fh.name.0 as usize].clone()
    };

    let Ok(pkg) = StoredPackage::from_modules_for_testing(TEST_ADDR, vec![module]) else {
        return Reach::NotSerializable;
    };

    let mut adapter = InMemoryTestAdapter::new();
    adapter.insert_package_into_storage(pkg);

    let Ok(linkage) = adapter.get_linkage_context(TEST_ADDR) else {
        return Reach::LoadFailed;
    };
    // Loading verifies + jits the package; a malformed module errors here.
    let Ok(mut vm) = adapter.make_vm(linkage) else {
        return Reach::LoadFailed;
    };

    let _ = vm.execute_function_bypass_visibility(
        &module_id,
        &run_name,
        vec![],
        vec![],
        &mut UnmeteredGasMeter,
        None,
    );
    Reach::Executed
}

/// Long-running seed-and-mutate campaign. See module docs for how to run.
#[test]
#[ignore = "long fuzz campaign; run with --release --features \"fuzzing testing\""]
fn fuzz_execute_no_panic() {
    const ITERATIONS: usize = 2_000;
    let mut rng = Rng(0x1CE_B00D_A11_C0DE);

    // Compile the seed once; confirm it executes clean before mutating.
    let seed = compile_seed();
    let run_idx = run_def_index(&seed);
    assert_eq!(
        publish_and_execute(seed.clone()),
        Reach::Executed,
        "unmutated seed must reach execution"
    );

    let prev_hook = panic::take_hook();
    panic::set_hook(Box::new(|_| {}));

    let mut failure: Option<(usize, Vec<u8>)> = None;
    let (mut executed, mut load_failed, mut not_ser) = (0usize, 0usize, 0usize);
    for i in 0..ITERATIONS {
        // Length biased small: single/double edits keep more modules verifiable.
        let len = (rng.next_u64() % 24) as usize + 1;
        let buf: Vec<u8> = (0..len).map(|_| rng.next_u64() as u8).collect();

        let mut u = Unstructured::new(&buf);
        let mut module = seed.clone();
        // Apply 1-2 mutations from the entropy.
        let n_muts = 1 + (buf.first().copied().unwrap_or(0) & 1) as usize;
        for _ in 0..n_muts {
            match Mutation::arbitrary(&mut u) {
                Ok(m) => apply_mutation(&mut module, run_idx, m),
                Err(_) => break,
            }
        }

        let res = panic::catch_unwind(AssertUnwindSafe(|| publish_and_execute(module)));
        match res {
            Ok(Reach::Executed) => executed += 1,
            Ok(Reach::LoadFailed) => load_failed += 1,
            Ok(Reach::NotSerializable) => not_ser += 1,
            Err(_) => {
                failure = Some((i, buf));
                break;
            }
        }
    }

    panic::set_hook(prev_hook);

    if let Some((i, buf)) = failure {
        let hex: String = buf.iter().map(|b| format!("{:02x}", b)).collect();
        panic!(
            "VM EXECUTE PANIC at iteration {i} (seed=0x1CE_B00D_A11_C0DE)\n\
             entropy ({} bytes) = {hex}\n",
            buf.len(),
        );
    }

    eprintln!(
        "fuzz_execute_no_panic: {ITERATIONS} iters | executed={executed} \
         load_failed={load_failed} not_serializable={not_ser} | no panic"
    );
}

/// Reproduce a specific failure from its hex entropy: paste the hex the campaign
/// printed into `entropy` and run explicitly (without catch_unwind, so the raw
/// panic + backtrace surfaces).
#[test]
#[ignore = "manual repro; paste failing entropy first"]
fn repro_execute_panic_raw() {
    let entropy = ""; // <- paste failing hex here
    if entropy.is_empty() {
        eprintln!("no entropy set; nothing to reproduce");
        return;
    }
    let buf: Vec<u8> = (0..entropy.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&entropy[i..i + 2], 16).unwrap())
        .collect();

    let seed = compile_seed();
    let run_idx = run_def_index(&seed);
    let mut u = Unstructured::new(&buf);
    let mut module = seed;
    let n_muts = 1 + (buf.first().copied().unwrap_or(0) & 1) as usize;
    for _ in 0..n_muts {
        if let Ok(m) = Mutation::arbitrary(&mut u) {
            apply_mutation(&mut module, run_idx, m);
        }
    }
    publish_and_execute(module);
}
