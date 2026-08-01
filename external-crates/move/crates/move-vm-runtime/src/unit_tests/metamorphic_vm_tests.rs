// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Metamorphic differential test for the new arena/JIT Move VM (protocol v118,
//! enabled unconditionally = live on mainnet).
//!
//! Standard fuzzers look for panics. This looks for something a panic-fuzzer
//! cannot see: a **semantics-preserving transformation of a module that changes
//! its result**. The new VM translates verified bytecode through a JIT
//! (`jit/execution/translate.rs`) that splits code into basic blocks and then
//! `flatten_and_renumber`s branch/jump-table offsets. An off-by-one or
//! mis-mapping there yields wrong control flow -- not a crash, a *different
//! answer*. On a validator that is a state fork (two honest nodes compute
//! different effects) or, via a corrupted branch, a type/reference confusion.
//!
//! Method: a self-checking seed function `run()` computes values through a loop,
//! nested branches, struct field borrows, and generic pack/unpack, and
//! `assert!`s every intermediate against a known constant -- so correct
//! execution returns `Ok(())` and any divergence aborts. We then apply
//! transformations that are *provably semantics-preserving at the Move
//! abstract-machine level*:
//!   1. Insert a `Nop` at each code offset, incrementing every branch/jump
//!      target `>= offset` (exhaustive sweep -- directly exercises the JIT's
//!      offset renumbering).
//!   2. Append unused trailing locals (exercises frame sizing).
//!
//! For each transform the outcome must be one of:
//!   * load-rejected (verifier legitimately refused the reshaped code) -> skip,
//!   * executed Ok -> good,
//! and MUST NOT be:
//!   * executed with an abort/error, or a panic -> the transform preserved
//!     semantics and the original succeeded, so a failure here is a
//!     JIT/execution miscompilation. THIS IS THE FINDING.
//!
//! Run with `--release --features "fuzzing testing"` (debug-only asserts inside
//! the verifier/interpreter would otherwise create false positives):
//! `cargo test --release --features "fuzzing testing" -p move-vm-runtime \
//!      metamorphic_execute_equivalence -- --ignored --nocapture`

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
use move_binary_format::file_format::{Bytecode, CompiledModule, SignatureToken};
use move_core_types::account_address::AccountAddress;
use std::panic::{self, AssertUnwindSafe};

const TEST_ADDR: AccountAddress = AccountAddress::new([42; AccountAddress::LENGTH]);

/// Self-checking seed. `run()` returns `Ok(())` iff every computed value matches
/// its expected constant; any control-flow or arithmetic divergence trips an
/// `assert!` and aborts. The loop + nested if/else give branch targets for the
/// Nop sweep to shift; the struct/reference/generic ops broaden interpreter
/// coverage.
/// Branch-heavy seed: loop + nested if/else + struct field borrow + generic
/// pack/unpack. Exercises the JIT branch-offset renumbering.
const SEED_SRC_BRANCHES: &str = r#"
module 0x2a::M {
    public struct S has drop { x: u64, y: bool }
    public struct G<T> has drop { v: T }

    fun wrap<T>(t: T): G<T> { G { v: t } }

    public fun run() {
        let mut v: u64 = 0;
        let mut i: u64 = 0;
        while (i < 10) {
            if (i % 3 == 0) {
                v = v + i
            } else if (i % 3 == 1) {
                v = v + i * 2
            } else {
                v = v + i * 3
            };
            i = i + 1;
        };
        // 0 +2 +6 +3 +8 +15 +6 +14 +24 +9 = 87
        assert!(v == 87, 1);

        let mut s = S { x: v, y: true };
        let r = &mut s.x;
        *r = *r + 13;
        assert!(s.x == 100, 2);

        let g = wrap<u64>(s.x);
        let G { v: gv } = g;
        assert!(gv == 100, 3);

        let b = s.y && (v > 50);
        assert!(b, 4);
    }
}
"#;

/// Enum/`match` seed: the `match` compiles to `VariantSwitch` + a jump table,
/// so the Nop sweep exercises the SEPARATE `compute_renumbered_jump_tables`
/// renumbering path (distinct from branch renumbering, and less trodden).
const SEED_SRC_ENUM: &str = r#"
module 0x2b::N {
    public enum E has drop { A, B(u64), C(u64, u64) }

    public fun run() {
        let mut total: u64 = 0;
        let mut i: u64 = 0;
        while (i < 6) {
            let e = if (i % 3 == 0) { E::A } else if (i % 3 == 1) { E::B(i) } else { E::C(i, i + 1) };
            let add = match (e) {
                E::A => 1,
                E::B(x) => x * 10,
                E::C(x, y) => x + y,
            };
            total = total + add;
            i = i + 1;
        };
        // A:1, B(1):10, C(2,3):5, A:1, B(4):40, C(5,6):11 = 68
        assert!(total == 68, 1);
    }
}
"#;

/// Deeply-nested control flow: nested loops with a three-way branch inside.
/// Maximizes the number of branch targets the Nop/Branch sweeps must renumber.
const SEED_SRC_NESTED: &str = r#"
module 0x2c::D {
    public fun run() {
        let mut acc: u64 = 0;
        let mut a: u64 = 0;
        while (a < 4) {
            let mut b: u64 = 0;
            while (b < 4) {
                if (a > b) {
                    if (a % 2 == 0) { acc = acc + a } else { acc = acc + b }
                } else if (a < b) {
                    acc = acc + (b - a)
                } else {
                    acc = acc + 1
                };
                b = b + 1;
            };
            a = a + 1;
        };
        assert!(acc == 21, 1);
    }
}
"#;

/// Reference-heavy: `&mut` passed to a helper, field borrows, read-refs.
const SEED_SRC_REFS: &str = r#"
module 0x2d::R {
    public struct P has drop { a: u64, b: u64 }

    fun bump(r: &mut u64, d: u64) { *r = *r + d; }

    public fun run() {
        let mut p = P { a: 10, b: 20 };
        bump(&mut p.a, 5);
        assert!(p.a == 15, 1);
        let x = *(&p.a);
        bump(&mut p.b, x);
        assert!(p.b == 35, 2);
        assert!(*(&p.a) + *(&p.b) == 50, 3);
    }
}
"#;

const SEEDS: &[(&str, &str)] = &[
    ("branches", SEED_SRC_BRANCHES),
    ("enum", SEED_SRC_ENUM),
    ("nested", SEED_SRC_NESTED),
    ("refs", SEED_SRC_REFS),
];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Outcome {
    /// Verifier/loader refused the reshaped module (legitimate for some Nop
    /// placements, e.g. dead code after a terminator).
    LoadRejected,
    /// Reached execution and returned normally.
    ExecOk,
    /// Reached execution and aborted/errored.
    ExecErr,
}

fn compile_seed(src: &str) -> CompiledModule {
    let mut units = compile_units(src).expect("seed source compiles");
    as_module(units.pop().unwrap())
}

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

fn run_module(module: CompiledModule) -> Outcome {
    let module_id = module.self_id();
    let run_name = {
        let idx = run_def_index(&module);
        let fh = &module.function_handles[module.function_defs[idx].function.0 as usize];
        module.identifiers[fh.name.0 as usize].clone()
    };

    let Ok(pkg) = StoredPackage::from_modules_for_testing(TEST_ADDR, vec![module]) else {
        return Outcome::LoadRejected;
    };
    let mut adapter = InMemoryTestAdapter::new();
    adapter.insert_package_into_storage(pkg);
    let Ok(linkage) = adapter.get_linkage_context(TEST_ADDR) else {
        return Outcome::LoadRejected;
    };
    let Ok(mut vm) = adapter.make_vm(linkage) else {
        return Outcome::LoadRejected;
    };

    match vm.execute_function_bypass_visibility(
        &module_id,
        &run_name,
        vec![],
        vec![],
        &mut UnmeteredGasMeter,
        None,
    ) {
        Ok(_) => Outcome::ExecOk,
        Err(_) => Outcome::ExecErr,
    }
}

/// Insert a `Nop` at code offset `p` in `run`, incrementing every branch target
/// AND every jump-table target `>= p` so the transform is semantics-preserving.
/// The jump-table fixup is what exercises `compute_renumbered_jump_tables`.
fn insert_nop(module: &mut CompiledModule, run_idx: usize, p: usize) -> bool {
    use move_binary_format::file_format::JumpTableInner;
    let code_unit = module.function_defs[run_idx].code.as_mut().unwrap();
    if p > code_unit.code.len() {
        return false;
    }
    for jt in code_unit.jump_tables.iter_mut() {
        let JumpTableInner::Full(offsets) = &mut jt.jump_table;
        for t in offsets.iter_mut() {
            if (*t as usize) >= p {
                *t += 1;
            }
        }
    }
    for instr in code_unit.code.iter_mut() {
        match instr {
            Bytecode::BrTrue(t) | Bytecode::BrFalse(t) | Bytecode::Branch(t) => {
                if (*t as usize) >= p {
                    *t += 1;
                }
            }
            _ => {}
        }
    }
    code_unit.code.insert(p, Bytecode::Nop);
    true
}

/// Insert an unconditional `Branch` to the immediately-following instruction at
/// offset `p` (semantically a fall-through, so behavior is unchanged), fixing up
/// every other branch/jump-table target `>= p`. Unlike a `Nop`, this splits the
/// basic block at `p`, exercising the JIT's block-boundary detection + edge
/// wiring, not just linear renumbering. Skips `p` at/after the last instruction
/// (a branch past the end would be invalid rather than a fall-through).
fn insert_branch_to_next(module: &mut CompiledModule, run_idx: usize, p: usize) -> bool {
    use move_binary_format::file_format::JumpTableInner;
    let code_unit = module.function_defs[run_idx].code.as_mut().unwrap();
    if p >= code_unit.code.len() {
        return false;
    }
    for jt in code_unit.jump_tables.iter_mut() {
        let JumpTableInner::Full(offsets) = &mut jt.jump_table;
        for t in offsets.iter_mut() {
            if (*t as usize) >= p {
                *t += 1;
            }
        }
    }
    for instr in code_unit.code.iter_mut() {
        match instr {
            Bytecode::BrTrue(t) | Bytecode::BrFalse(t) | Bytecode::Branch(t) => {
                if (*t as usize) >= p {
                    *t += 1;
                }
            }
            _ => {}
        }
    }
    // Branch to p+1 == the original instruction at p (now shifted to p+1).
    code_unit.code.insert(p, Bytecode::Branch((p + 1) as u16));
    true
}

/// Append `n` unused local slots to `run`'s locals signature. Unused locals are
/// verifier-legal and never touched at runtime, so this is semantics-preserving;
/// it exercises frame sizing in the interpreter/JIT.
fn append_unused_locals(module: &mut CompiledModule, run_idx: usize, n: usize) {
    let locals_idx = module.function_defs[run_idx]
        .code
        .as_ref()
        .unwrap()
        .locals
        .0 as usize;
    let sig = &mut module.signatures[locals_idx].0;
    for _ in 0..n {
        sig.push(SignatureToken::U64);
    }
}

#[test]
#[ignore = "run with --release --features \"fuzzing testing\""]
fn metamorphic_execute_equivalence() {
    let mut findings: Vec<String> = Vec::new();
    let (mut ok, mut rejected, mut sweeps) = (0usize, 0usize, 0usize);

    let prev_hook = panic::take_hook();
    panic::set_hook(Box::new(|_| {}));

    for (seed_name, src) in SEEDS {
        let seed = compile_seed(src);
        let run_idx = run_def_index(&seed);
        let has_jt = !seed.function_defs[run_idx]
            .code
            .as_ref()
            .unwrap()
            .jump_tables
            .is_empty();

        // Baseline: the unmutated seed must execute cleanly. If not, the seed's
        // expected constants are wrong -- fix the seed, not the VM.
        assert_eq!(
            run_module(seed.clone()),
            Outcome::ExecOk,
            "unmutated seed '{seed_name}' must execute Ok; adjust seed constants"
        );

        let orig_len = seed.function_defs[run_idx]
            .code
            .as_ref()
            .unwrap()
            .code
            .len();
        eprintln!(
            "seed '{seed_name}': {orig_len} instrs, jump_tables={}",
            has_jt
        );
        sweeps += 1;

        // Transform 1: exhaustive single-Nop insertion at every offset.
        for p in 0..=orig_len {
            let mut m = seed.clone();
            if !insert_nop(&mut m, run_idx, p) {
                continue;
            }
            match panic::catch_unwind(AssertUnwindSafe(|| run_module(m))) {
                Ok(Outcome::ExecOk) => ok += 1,
                Ok(Outcome::LoadRejected) => rejected += 1,
                Ok(Outcome::ExecErr) => {
                    findings.push(format!("[{seed_name}] Nop@{p}: preserving insert -> ExecErr"));
                }
                Err(_) => {
                    findings.push(format!("[{seed_name}] Nop@{p}: preserving insert -> PANIC"));
                }
            }
        }

        // Transform 2: two-Nop insertions at every pair of offsets (compounds
        // the renumbering so a single-insert-safe off-by-one can still surface).
        for a in 0..=orig_len {
            for b in 0..=orig_len {
                let mut m = seed.clone();
                if !insert_nop(&mut m, run_idx, a) {
                    continue;
                }
                // second insert shifts by the first; insert at b adjusted.
                let b2 = if b >= a { b + 1 } else { b };
                if !insert_nop(&mut m, run_idx, b2) {
                    continue;
                }
                match panic::catch_unwind(AssertUnwindSafe(|| run_module(m))) {
                    Ok(Outcome::ExecOk) => ok += 1,
                    Ok(Outcome::LoadRejected) => rejected += 1,
                    Ok(Outcome::ExecErr) => {
                        findings.push(format!("[{seed_name}] Nop@{a},{b2}: preserving -> ExecErr"));
                    }
                    Err(_) => {
                        findings.push(format!("[{seed_name}] Nop@{a},{b2}: preserving -> PANIC"));
                    }
                }
            }
        }

        // Transform 3: unconditional Branch-to-next at every offset (splits the
        // basic block, exercising block-boundary detection + edge wiring).
        for p in 0..orig_len {
            let mut m = seed.clone();
            if !insert_branch_to_next(&mut m, run_idx, p) {
                continue;
            }
            match panic::catch_unwind(AssertUnwindSafe(|| run_module(m))) {
                Ok(Outcome::ExecOk) => ok += 1,
                Ok(Outcome::LoadRejected) => rejected += 1,
                Ok(Outcome::ExecErr) => {
                    findings.push(format!("[{seed_name}] Branch->next@{p}: preserving -> ExecErr"));
                }
                Err(_) => {
                    findings.push(format!("[{seed_name}] Branch->next@{p}: preserving -> PANIC"));
                }
            }
        }

        // Transform 4: unused trailing locals (a range of counts).
        for n in [1usize, 2, 4, 8, 32, 200] {
            let mut m = seed.clone();
            append_unused_locals(&mut m, run_idx, n);
            match panic::catch_unwind(AssertUnwindSafe(|| run_module(m))) {
                Ok(Outcome::ExecOk) => ok += 1,
                Ok(Outcome::LoadRejected) => rejected += 1,
                Ok(Outcome::ExecErr) => {
                    findings.push(format!("[{seed_name}] +{n} unused locals -> ExecErr"));
                }
                Err(_) => {
                    findings.push(format!("[{seed_name}] +{n} unused locals -> PANIC"));
                }
            }
        }
    }

    panic::set_hook(prev_hook);

    if !findings.is_empty() {
        panic!(
            "METAMORPHIC DIVERGENCE ({} finding(s)) -- semantics-preserving \
             transforms changed the result (JIT/execution miscompilation):\n{}",
            findings.len(),
            findings.join("\n")
        );
    }

    eprintln!(
        "metamorphic_execute_equivalence: {sweeps} seeds swept, \
         {ok} executed-equivalent, {rejected} load-rejected, no divergence"
    );
}
