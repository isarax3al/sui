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

    public fun run(): u64 {
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

        // Return a value derived from the whole computation so the differential
        // check catches data divergence even if it would not trip an assert.
        v + s.x + gv + (if (b) { 7 } else { 0 })
    }
}
"#;

/// Enum/`match` seed: the `match` compiles to `VariantSwitch` + a jump table,
/// so the Nop sweep exercises the SEPARATE `compute_renumbered_jump_tables`
/// renumbering path (distinct from branch renumbering, and less trodden).
const SEED_SRC_ENUM: &str = r#"
module 0x2b::N {
    public enum E has drop { A, B(u64), C(u64, u64) }

    public fun run(): u64 {
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
        total
    }
}
"#;

/// Deeply-nested control flow: nested loops with a three-way branch inside.
/// Maximizes the number of branch targets the Nop/Branch sweeps must renumber.
const SEED_SRC_NESTED: &str = r#"
module 0x2c::D {
    public fun run(): u64 {
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
        acc
    }
}
"#;

/// Reference-heavy: `&mut` passed to a helper, field borrows, read-refs.
const SEED_SRC_REFS: &str = r#"
module 0x2d::R {
    public struct P has drop { a: u64, b: u64 }

    fun bump(r: &mut u64, d: u64) { *r = *r + d; }

    public fun run(): u64 {
        let mut p = P { a: 10, b: 20 };
        bump(&mut p.a, 5);
        assert!(p.a == 15, 1);
        let x = *(&p.a);
        bump(&mut p.b, x);
        assert!(p.b == 35, 2);
        assert!(*(&p.a) + *(&p.b) == 50, 3);
        p.a + p.b
    }
}
"#;

/// Operation-coverage seed: every integer width, checked casts up and down,
/// bit ops, shifts, u128/u256 arithmetic, all comparisons, and boolean logic,
/// each self-checked against a known constant. A JIT mistranslation of any
/// single operation trips its assert (so the baseline itself fails), and the
/// metamorphic sweeps additionally reshape code containing all of these ops.
const SEED_SRC_OPS: &str = r#"
module 0x2e::Ops {
    public fun run(): u64 {
        // bit ops (u64)
        assert!((0xF0u64 & 0x0Fu64) == 0, 1);
        assert!((0xF0u64 | 0x0Fu64) == 255, 2);
        assert!((0xFFu64 ^ 0x0Fu64) == 240, 3);
        assert!((1u64 << 10) == 1024, 4);
        assert!((1024u64 >> 3) == 128, 5);

        // arithmetic (u64)
        assert!((7u64 / 2) == 3, 6);
        assert!((7u64 % 2) == 1, 7);
        assert!((6u64 * 7) == 42, 8);
        assert!((100u64 - 58) == 42, 9);

        // comparisons
        assert!(3u64 < 4, 10);
        assert!(4u64 > 3, 11);
        assert!(4u64 <= 4, 12);
        assert!(4u64 >= 4, 13);
        assert!(5u64 == 5, 14);
        assert!(5u64 != 6, 15);

        // bool logic
        assert!(true && true, 16);
        assert!(true || false, 17);
        assert!(!false, 18);

        // casts up
        let a: u8 = 250;
        assert!((a as u16) == 250, 19);
        assert!((a as u32) == 250, 20);
        assert!((a as u64) == 250, 21);
        assert!((a as u128) == 250, 22);
        assert!((a as u256) == 250, 23);
        // casts down (values in range)
        assert!((250u256 as u8) == 250, 24);
        assert!((65535u64 as u16) == 65535, 25);

        // u128 arithmetic
        let big: u128 = 1000000000000u128 * 1000000u128; // 1e18
        assert!(big == 1000000000000000000, 26);
        assert!(big / 1000000u128 == 1000000000000, 27);

        // u256 shifts and arithmetic
        let s: u256 = 1u256 << 200;
        assert!(s >> 200 == 1, 28);
        assert!(s / (1u256 << 100) == (1u256 << 100), 29);
        let m: u256 = (1u256 << 128) + 12345;
        assert!(m % (1u256 << 128) == 12345, 30);

        // u16 / u32 arithmetic (near width limits)
        assert!((60000u16 + 5000u16) == 65000, 31);
        assert!((3000000000u32 + 1000000000u32) == 4000000000, 32);
        assert!((4000000000u32 - 3999999999u32) == 1, 33);

        let mut acc: u64 = 0;
        acc = acc + (0xFFu64 | 0x100u64);                     // 511
        acc = acc + (1u64 << 5);                              // 32
        acc = acc + ((big / 1000000000000000u128) as u64);    // 1000
        assert!(acc == 1543, 34);
        acc
    }
}
"#;

/// Multi-module seed: `Caller::run` dispatches into another module `Lib` in the
/// same package, so the sweep reshapes a caller whose control flow surrounds
/// cross-module `Call`s -- exercising the vtable `resolve_function` path (and
/// its interaction with offset renumbering) that single-module seeds do not.
const SEED_SRC_MULTIMOD: &str = r#"
module 0x2f::Lib {
    public fun square(x: u64): u64 { x * x }
    public fun add3(a: u64, b: u64, c: u64): u64 { a + b + c }
}
module 0x2f::Caller {
    use 0x2f::Lib;
    public fun run(): u64 {
        let mut acc: u64 = 0;
        let mut i: u64 = 0;
        while (i < 5) {
            if (i % 2 == 0) {
                acc = acc + Lib::square(i)
            } else {
                acc = acc + Lib::add3(i, i, i)
            };
            i = i + 1;
        };
        // i=0:sq0=0, 1:add3(3)=3, 2:sq4=4, 3:add3(9)=9, 4:sq16=16 => 32
        assert!(acc == 32, 1);
        acc
    }
}
"#;

const SEEDS: &[(&str, &str)] = &[
    ("branches", SEED_SRC_BRANCHES),
    ("enum", SEED_SRC_ENUM),
    ("nested", SEED_SRC_NESTED),
    ("refs", SEED_SRC_REFS),
    ("ops", SEED_SRC_OPS),
    ("multimod", SEED_SRC_MULTIMOD),
];

#[derive(Clone, PartialEq, Eq, Debug)]
enum Outcome {
    /// Verifier/loader refused the reshaped module (legitimate for some Nop
    /// placements, e.g. dead code after a terminator).
    LoadRejected,
    /// Reached execution and returned normally, carrying the concatenated BCS
    /// bytes of the returned values (so two Ok outcomes can be compared for
    /// value equality, not just success).
    ExecOk(Vec<u8>),
    /// Reached execution and aborted/errored.
    ExecErr,
}

fn compile_seed(src: &str) -> Vec<CompiledModule> {
    compile_units(src)
        .expect("seed source compiles")
        .into_iter()
        .map(as_module)
        .collect()
}

/// Locate the `(module_index, function_def_index)` of the `run` function across
/// a (possibly multi-module) seed package.
fn locate_run(modules: &[CompiledModule]) -> (usize, usize) {
    for (mi, m) in modules.iter().enumerate() {
        if let Some(di) = m.function_defs.iter().position(|fd| {
            let fh = &m.function_handles[fd.function.0 as usize];
            m.identifiers[fh.name.0 as usize].as_str() == "run"
        }) {
            return (mi, di);
        }
    }
    panic!("seed has no run()")
}

fn run_module(modules: Vec<CompiledModule>) -> Outcome {
    let (mi, di) = locate_run(&modules);
    let module_id = modules[mi].self_id();
    let run_name = {
        let m = &modules[mi];
        let fh = &m.function_handles[m.function_defs[di].function.0 as usize];
        m.identifiers[fh.name.0 as usize].clone()
    };

    let Ok(pkg) = StoredPackage::from_modules_for_testing(TEST_ADDR, modules) else {
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
        Ok(vals) => {
            let mut bytes = Vec::new();
            for v in &vals {
                match v.serialize() {
                    Some(b) => {
                        bytes.extend((b.len() as u32).to_le_bytes());
                        bytes.extend(b);
                    }
                    // A returned value that cannot be serialized (e.g. a
                    // reference) is not something these seeds produce; mark it
                    // distinctly so it never silently compares equal.
                    None => bytes.extend(b"<unserializable>"),
                }
            }
            Outcome::ExecOk(bytes)
        }
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
        let (mi, run_idx) = locate_run(&seed);
        let has_jt = !seed[mi].function_defs[run_idx]
            .code
            .as_ref()
            .unwrap()
            .jump_tables
            .is_empty();

        // Baseline: the unmutated seed must execute cleanly and return a value.
        // If not, the seed itself is wrong -- fix the seed, not the VM.
        let base_bytes = match run_module(seed.clone()) {
            Outcome::ExecOk(b) => b,
            other => panic!("unmutated seed '{seed_name}' must execute Ok, got {other:?}"),
        };

        let orig_len = seed[mi].function_defs[run_idx]
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

        // Classify one transformed run against the baseline. A reshaped module
        // that LOADS must execute to the SAME return bytes; an abort, a panic,
        // or a *different return value* is a JIT/execution miscompilation.
        let mut classify = |res: std::thread::Result<Outcome>, label: String| match res {
            Ok(Outcome::ExecOk(b)) => {
                if b == base_bytes {
                    ok += 1;
                } else {
                    findings.push(format!("{label} -> DIFFERENT RETURN VALUE"));
                }
            }
            Ok(Outcome::LoadRejected) => rejected += 1,
            Ok(Outcome::ExecErr) => findings.push(format!("{label} -> ExecErr")),
            Err(_) => findings.push(format!("{label} -> PANIC")),
        };

        // Transform 1: exhaustive single-Nop insertion at every offset.
        for p in 0..=orig_len {
            let mut m = seed.clone();
            if !insert_nop(&mut m[mi], run_idx, p) {
                continue;
            }
            let res = panic::catch_unwind(AssertUnwindSafe(|| run_module(m)));
            classify(res, format!("[{seed_name}] Nop@{p}"));
        }

        // Transform 2: two-Nop insertions at every pair of offsets (compounds
        // the renumbering so a single-insert-safe off-by-one can still surface).
        // O(n^2), so only for the shorter seeds; long seeds rely on the linear
        // single-Nop / Branch sweeps plus the baseline op-correctness check.
        if orig_len <= 130 {
            for a in 0..=orig_len {
                for b in 0..=orig_len {
                    let mut m = seed.clone();
                    if !insert_nop(&mut m[mi], run_idx, a) {
                        continue;
                    }
                    // second insert shifts by the first; insert at b adjusted.
                    let b2 = if b >= a { b + 1 } else { b };
                    if !insert_nop(&mut m[mi], run_idx, b2) {
                        continue;
                    }
                    let res = panic::catch_unwind(AssertUnwindSafe(|| run_module(m)));
                    classify(res, format!("[{seed_name}] Nop@{a},{b2}"));
                }
            }
        }

        // Transform 3: unconditional Branch-to-next at every offset (splits the
        // basic block, exercising block-boundary detection + edge wiring).
        for p in 0..orig_len {
            let mut m = seed.clone();
            if !insert_branch_to_next(&mut m[mi], run_idx, p) {
                continue;
            }
            let res = panic::catch_unwind(AssertUnwindSafe(|| run_module(m)));
            classify(res, format!("[{seed_name}] Branch->next@{p}"));
        }

        // Transform 4: unused trailing locals (a range of counts).
        for n in [1usize, 2, 4, 8, 32, 200] {
            let mut m = seed.clone();
            append_unused_locals(&mut m[mi], run_idx, n);
            let res = panic::catch_unwind(AssertUnwindSafe(|| run_module(m)));
            classify(res, format!("[{seed_name}] +{n} unused locals"));
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
