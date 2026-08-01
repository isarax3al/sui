// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Cross-version differential test: the NEW arena/JIT VM (this crate, protocol
//! v118, live on mainnet) vs the OLD v3 VM (`move-vm-runtime-v3`, years-proven
//! on mainnet).
//!
//! The new VM is a performance *rewrite* that is supposed to be **semantically
//! identical** to v3 for every existing Move program -- intended changes are
//! additive (new bytecodes/natives), never changed behavior of existing
//! operations. So for a standard Move program that both VMs accept, they MUST
//! produce identical return values. The old VM is the oracle (its behavior is
//! what mainnet has executed for years); any divergence is a bug in the NEW VM,
//! and a divergence in on-chain execution is a consensus fork / miscompilation
//! = critical.
//!
//! Each seed's `run()` returns a value computed through arithmetic, casts, bit
//! ops, shifts, u128/u256, control flow, references, and cross-module calls. We
//! run the SAME compiled module through both VMs and compare the serialized
//! return bytes. A `DIVERGENCE` (both execute but return different bytes, or one
//! succeeds while the other aborts) is the finding.
//!
//! Run with `--release --features "fuzzing testing"`:
//! `cargo test --release --features "fuzzing testing" -p move-vm-runtime \
//!      differential_new_vs_old_vm -- --ignored --nocapture`

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
use move_binary_format::{errors::VMError, file_format::CompiledModule};
use move_core_types::{
    account_address::AccountAddress,
    language_storage::ModuleId,
    resolver::{ModuleResolver, SerializedPackage},
};
use std::collections::HashMap;

// v3 (old) VM.
use move_vm_runtime_v3::move_vm::MoveVM as MoveVmV3;
use move_vm_types_v3::{data_store::LinkageResolver, gas::UnmeteredGasMeter as UnmeteredGasMeterV3};

const TEST_ADDR: AccountAddress = AccountAddress::new([42; AccountAddress::LENGTH]);

/// Standard-Move seeds; each `run()` returns a u64 computed through a broad
/// slice of the language. Everything here exists in both VM versions.
const SEEDS: &[(&str, &str)] = &[
    (
        "ops",
        r#"
module 0x40::Ops {
    public fun run(): u64 {
        let mut acc: u64 = 0;
        acc = acc + (0xF0u64 & 0x0Fu64);
        acc = acc + (0xF0u64 | 0x0Fu64);
        acc = acc + (0xFFu64 ^ 0x0Fu64);
        acc = acc + (1u64 << 10);
        acc = acc + (1024u64 >> 3);
        acc = acc + (7u64 / 2) + (7u64 % 2) + (6u64 * 7);
        let big: u128 = 1000000000000u128 * 1000000u128;
        acc = acc + ((big / 1000000000000000u128) as u64);
        let s: u256 = 1u256 << 200;
        acc = acc + ((s >> 200) as u64);
        let m: u256 = ((1u256 << 128) + 5) % (1u256 << 128);
        acc = acc + (m as u64);
        acc
    }
}
"#,
    ),
    (
        "nested",
        r#"
module 0x41::Nested {
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
        acc
    }
}
"#,
    ),
    (
        "refs",
        r#"
module 0x42::Refs {
    public struct P has drop { a: u64, b: u64 }
    fun bump(r: &mut u64, d: u64) { *r = *r + d; }
    public fun run(): u64 {
        let mut p = P { a: 10, b: 20 };
        bump(&mut p.a, 5);
        let x = *(&p.a);
        bump(&mut p.b, x);
        p.a + p.b
    }
}
"#,
    ),
    (
        "generics",
        r#"
module 0x43::Gen {
    public struct G<T> has drop { v: T }
    fun wrap<T>(t: T): G<T> { G { v: t } }
    public fun run(): u64 {
        let g = wrap<u64>(1234);
        let G { v } = g;
        v * 2
    }
}
"#,
    ),
    (
        "multimod",
        r#"
module 0x44::Lib {
    public fun square(x: u64): u64 { x * x }
    public fun add3(a: u64, b: u64, c: u64): u64 { a + b + c }
}
module 0x44::Caller {
    use 0x44::Lib;
    public fun run(): u64 {
        let mut acc: u64 = 0;
        let mut i: u64 = 0;
        while (i < 5) {
            if (i % 2 == 0) { acc = acc + Lib::square(i) } else { acc = acc + Lib::add3(i, i, i) };
            i = i + 1;
        };
        acc
    }
}
"#,
    ),
];

#[derive(Clone, PartialEq, Eq, Debug)]
enum Outcome {
    /// Verifier/loader/feature gap in this VM (module not accepted).
    NotAccepted,
    /// Executed and returned normally, with per-value serialized bytes.
    Ok(Vec<Vec<u8>>),
    /// Executed and aborted/errored.
    Err,
}

fn compile(src: &str) -> Vec<CompiledModule> {
    compile_units(src)
        .expect("seed compiles")
        .into_iter()
        .map(as_module)
        .collect()
}

fn locate_run(modules: &[CompiledModule]) -> (usize, move_core_types::identifier::Identifier) {
    for (mi, m) in modules.iter().enumerate() {
        if let Some(fd) = m.function_defs.iter().find(|fd| {
            let fh = &m.function_handles[fd.function.0 as usize];
            m.identifiers[fh.name.0 as usize].as_str() == "run"
        }) {
            let fh = &m.function_handles[fd.function.0 as usize];
            return (mi, m.identifiers[fh.name.0 as usize].to_owned());
        }
    }
    panic!("seed has no run()")
}

/// Execute `run` through the NEW VM.
fn run_new(modules: &[CompiledModule]) -> Outcome {
    let (mi, run_name) = locate_run(modules);
    let module_id = modules[mi].self_id();
    let Ok(pkg) = StoredPackage::from_modules_for_testing(TEST_ADDR, modules.to_vec()) else {
        return Outcome::NotAccepted;
    };
    let mut adapter = InMemoryTestAdapter::new();
    adapter.insert_package_into_storage(pkg);
    let Ok(linkage) = adapter.get_linkage_context(TEST_ADDR) else {
        return Outcome::NotAccepted;
    };
    let Ok(mut vm) = adapter.make_vm(linkage) else {
        return Outcome::NotAccepted;
    };
    match vm.execute_function_bypass_visibility(
        &module_id,
        &run_name,
        vec![],
        vec![],
        &mut UnmeteredGasMeter,
        None,
    ) {
        Ok(vals) => Outcome::Ok(
            vals.iter()
                .map(|v| v.serialize().unwrap_or_default())
                .collect(),
        ),
        Err(_) => Outcome::Err,
    }
}

/// Minimal module resolver for the v3 VM (mirrors v3's own test `RemoteStore`).
struct V3Store {
    modules: HashMap<ModuleId, Vec<u8>>,
}
impl V3Store {
    fn new(modules: &[CompiledModule]) -> Self {
        let mut m = HashMap::new();
        for cm in modules {
            let mut bytes = vec![];
            cm.serialize_with_version(cm.version(), &mut bytes).unwrap();
            m.insert(cm.self_id(), bytes);
        }
        Self { modules: m }
    }
}
impl LinkageResolver for V3Store {
    type Error = VMError;
}
impl ModuleResolver for V3Store {
    type Error = VMError;
    fn get_module(&self, id: &ModuleId) -> Result<Option<Vec<u8>>, Self::Error> {
        Ok(self.modules.get(id).cloned())
    }
    fn get_packages_static<const N: usize>(
        &self,
        _ids: [AccountAddress; N],
    ) -> Result<[Option<SerializedPackage>; N], Self::Error> {
        unreachable!("not used by v3")
    }
    fn get_packages<'a>(
        &self,
        _ids: impl ExactSizeIterator<Item = &'a AccountAddress>,
    ) -> Result<Vec<Option<SerializedPackage>>, Self::Error> {
        unreachable!("not used by v3")
    }
}

/// Execute `run` through the OLD v3 VM.
fn run_old(modules: &[CompiledModule]) -> Outcome {
    let (mi, run_name) = locate_run(modules);
    let module_id = modules[mi].self_id();
    let Ok(vm) = MoveVmV3::new(vec![]) else {
        return Outcome::NotAccepted;
    };
    let store = V3Store::new(modules);
    let mut session = vm.new_session(&store);
    match session.execute_function_bypass_visibility(
        &module_id,
        &run_name,
        Vec::new(),               // ty_args
        Vec::<Vec<u8>>::new(),    // serialized value args
        &mut UnmeteredGasMeterV3,
        None,
    ) {
        Ok(rv) => Outcome::Ok(rv.return_values.into_iter().map(|(b, _)| b).collect()),
        Err(_) => Outcome::Err,
    }
}

#[test]
#[ignore = "run with --release --features \"fuzzing testing\""]
fn differential_new_vs_old_vm() {
    let mut findings: Vec<String> = Vec::new();
    let mut compared = 0usize;

    for (name, src) in SEEDS {
        let modules = compile(src);
        let new = run_new(&modules);
        let old = run_old(&modules);

        match (&new, &old) {
            // The interesting invariant: both accept and execute -> results must
            // be identical.
            (Outcome::Ok(a), Outcome::Ok(b)) => {
                compared += 1;
                if a != b {
                    findings.push(format!(
                        "[{name}] DIVERGENCE: new={a:?} old={b:?}"
                    ));
                }
            }
            // Both abort: consistent.
            (Outcome::Err, Outcome::Err) => compared += 1,
            // One executes-Ok while the other aborts on the same module: a real
            // behavioral divergence.
            (Outcome::Ok(_), Outcome::Err) | (Outcome::Err, Outcome::Ok(_)) => {
                findings.push(format!(
                    "[{name}] DIVERGENCE: new={new:?} old={old:?} (one Ok, one abort)"
                ));
            }
            // One VM did not accept the module (feature/verifier gap): not a
            // semantic divergence for the shared surface; log and skip.
            _ => {
                eprintln!("[{name}] skipped (acceptance differs): new={new:?} old={old:?}");
            }
        }
    }

    if !findings.is_empty() {
        panic!(
            "CROSS-VERSION VM DIVERGENCE ({} finding(s)) -- new VM disagrees with \
             proven v3 VM on standard Move (consensus-fork / miscompilation class):\n{}",
            findings.len(),
            findings.join("\n")
        );
    }

    eprintln!(
        "differential_new_vs_old_vm: {compared}/{} seeds executed identically on both VMs",
        SEEDS.len()
    );
}
