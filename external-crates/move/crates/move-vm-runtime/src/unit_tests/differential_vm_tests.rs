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

use crate::dev_utils::{
    compilation_utils::{as_module, compile_units},
    in_memory_test_adapter::InMemoryTestAdapter,
    storage::StoredPackage,
    vm_test_adapter::VMTestAdapter,
};
use arbitrary::{Arbitrary, Unstructured};
use move_binary_format::{
    errors::{PartialVMError, PartialVMResult, VMError},
    file_format::{Bytecode, CompiledModule},
};
use move_core_types::{
    account_address::AccountAddress,
    gas_algebra::{InternalGas, NumArgs, NumBytes},
    language_storage::ModuleId,
    resolver::{ModuleResolver, SerializedPackage},
    vm_status::StatusCode,
};
use std::collections::HashMap;

// v3 (old) VM.
use move_vm_runtime_v3::move_vm::MoveVM as MoveVmV3;
use move_vm_types_v3::data_store::LinkageResolver;

const TEST_ADDR: AccountAddress = AccountAddress::new([42; AccountAddress::LENGTH]);

/// Max Move-bytecode "steps" (one per gas-charge callback) before execution is
/// forced to abort with OUT_OF_GAS. This bounds infinite-loop mutants so the
/// fuzzer cannot hang. It is set enormously higher than any legitimate mutant
/// needs (the seeds run <10^4 steps), so a real finite computation always
/// completes in BOTH VMs and only genuinely non-terminating mutants hit the cap
/// -- in which case both VMs hit it, keeping the comparison fair.
const STEP_BUDGET: u64 = 1_000_000;

/// A uniform step-counting gas meter: every gas-charge callback consumes exactly
/// one step. Because both VMs charge (at least) once per executed bytecode, a
/// program that runs forever is aborted after `STEP_BUDGET` steps in each,
/// rather than the two VMs disagreeing at a per-instruction gas-cost boundary.
struct StepMeter {
    left: u64,
}
impl StepMeter {
    fn new(n: u64) -> Self {
        Self { left: n }
    }
    fn tick(&mut self) -> PartialVMResult<()> {
        if self.left == 0 {
            return Err(PartialVMError::new(StatusCode::OUT_OF_GAS));
        }
        self.left -= 1;
        Ok(())
    }
}

// --- new VM's GasMeter ---
mod new_gas {
    pub use crate::shared::gas::{GasMeter, SimpleInstruction};
    pub use crate::shared::views::ValueView;
}
impl new_gas::GasMeter for StepMeter {
    fn charge_simple_instr(&mut self, _i: new_gas::SimpleInstruction) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_pop(&mut self, _v: impl new_gas::ValueView) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_call(
        &mut self,
        _m: &ModuleId,
        _f: &str,
        _a: impl IntoIterator<Item = impl new_gas::ValueView>,
        _n: NumArgs,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_call_generic(
        &mut self,
        _m: &ModuleId,
        _f: &str,
        _a: impl ExactSizeIterator<Item = impl new_gas::ValueView>,
        _n: NumArgs,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_ld_const(&mut self, _s: NumBytes) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_ld_const_after_deserialization(
        &mut self,
        _v: impl new_gas::ValueView,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_copy_loc(&mut self, _v: impl new_gas::ValueView) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_move_loc(&mut self, _v: impl new_gas::ValueView) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_store_loc(&mut self, _v: impl new_gas::ValueView) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_pack(
        &mut self,
        _g: bool,
        _a: impl ExactSizeIterator<Item = impl new_gas::ValueView>,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_unpack(
        &mut self,
        _g: bool,
        _a: impl ExactSizeIterator<Item = impl new_gas::ValueView>,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_variant_switch(&mut self, _v: impl new_gas::ValueView) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_read_ref(&mut self, _v: impl new_gas::ValueView) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_write_ref(
        &mut self,
        _n: impl new_gas::ValueView,
        _o: impl new_gas::ValueView,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_eq(
        &mut self,
        _l: impl new_gas::ValueView,
        _r: impl new_gas::ValueView,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_neq(
        &mut self,
        _l: impl new_gas::ValueView,
        _r: impl new_gas::ValueView,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_vec_pack<'a>(
        &mut self,
        _a: impl ExactSizeIterator<Item = impl new_gas::ValueView>,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_vec_len(&mut self) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_vec_borrow(&mut self, _m: bool, _s: bool) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_vec_push_back(&mut self, _v: impl new_gas::ValueView) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_vec_pop_back(&mut self, _v: Option<impl new_gas::ValueView>) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_vec_unpack(
        &mut self,
        _n: NumArgs,
        _e: impl ExactSizeIterator<Item = impl new_gas::ValueView>,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_vec_swap(&mut self) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_native_function(
        &mut self,
        _a: InternalGas,
        _r: Option<impl ExactSizeIterator<Item = impl new_gas::ValueView>>,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_native_function_before_execution(
        &mut self,
        _a: impl ExactSizeIterator<Item = impl new_gas::ValueView>,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_drop_frame(
        &mut self,
        _l: impl Iterator<Item = impl new_gas::ValueView>,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn remaining_gas(&self) -> InternalGas {
        InternalGas::new(self.left)
    }
}

// --- v3 VM's GasMeter (has extra TypeView params) ---
mod v3_gas {
    pub use move_vm_types_v3::gas::{GasMeter, SimpleInstruction};
    pub use move_vm_types_v3::views::{TypeView, ValueView};
}
impl v3_gas::GasMeter for StepMeter {
    fn charge_simple_instr(&mut self, _i: v3_gas::SimpleInstruction) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_pop(&mut self, _v: impl v3_gas::ValueView) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_call(
        &mut self,
        _m: &ModuleId,
        _f: &str,
        _a: impl IntoIterator<Item = impl v3_gas::ValueView>,
        _n: NumArgs,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_call_generic(
        &mut self,
        _m: &ModuleId,
        _f: &str,
        _t: impl ExactSizeIterator<Item = impl v3_gas::TypeView>,
        _a: impl ExactSizeIterator<Item = impl v3_gas::ValueView>,
        _n: NumArgs,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_ld_const(&mut self, _s: NumBytes) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_ld_const_after_deserialization(
        &mut self,
        _v: impl v3_gas::ValueView,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_copy_loc(&mut self, _v: impl v3_gas::ValueView) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_move_loc(&mut self, _v: impl v3_gas::ValueView) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_store_loc(&mut self, _v: impl v3_gas::ValueView) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_pack(
        &mut self,
        _g: bool,
        _a: impl ExactSizeIterator<Item = impl v3_gas::ValueView>,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_unpack(
        &mut self,
        _g: bool,
        _a: impl ExactSizeIterator<Item = impl v3_gas::ValueView>,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_variant_switch(&mut self, _v: impl v3_gas::ValueView) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_read_ref(&mut self, _v: impl v3_gas::ValueView) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_write_ref(
        &mut self,
        _n: impl v3_gas::ValueView,
        _o: impl v3_gas::ValueView,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_eq(
        &mut self,
        _l: impl v3_gas::ValueView,
        _r: impl v3_gas::ValueView,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_neq(
        &mut self,
        _l: impl v3_gas::ValueView,
        _r: impl v3_gas::ValueView,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_vec_pack<'a>(
        &mut self,
        _ty: impl v3_gas::TypeView + 'a,
        _a: impl ExactSizeIterator<Item = impl v3_gas::ValueView>,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_vec_len(&mut self, _ty: impl v3_gas::TypeView) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_vec_borrow(
        &mut self,
        _m: bool,
        _ty: impl v3_gas::TypeView,
        _s: bool,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_vec_push_back(
        &mut self,
        _ty: impl v3_gas::TypeView,
        _v: impl v3_gas::ValueView,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_vec_pop_back(
        &mut self,
        _ty: impl v3_gas::TypeView,
        _v: Option<impl v3_gas::ValueView>,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_vec_unpack(
        &mut self,
        _ty: impl v3_gas::TypeView,
        _n: NumArgs,
        _e: impl ExactSizeIterator<Item = impl v3_gas::ValueView>,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_vec_swap(&mut self, _ty: impl v3_gas::TypeView) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_native_function(
        &mut self,
        _a: InternalGas,
        _r: Option<impl ExactSizeIterator<Item = impl v3_gas::ValueView>>,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_native_function_before_execution(
        &mut self,
        _t: impl ExactSizeIterator<Item = impl v3_gas::TypeView>,
        _a: impl ExactSizeIterator<Item = impl v3_gas::ValueView>,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn charge_drop_frame(
        &mut self,
        _l: impl Iterator<Item = impl v3_gas::ValueView>,
    ) -> PartialVMResult<()> {
        self.tick()
    }
    fn remaining_gas(&self) -> InternalGas {
        InternalGas::new(self.left)
    }
}

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
        &mut StepMeter::new(STEP_BUDGET),
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
        &mut StepMeter::new(STEP_BUDGET),
        None,
    ) {
        Ok(rv) => Outcome::Ok(rv.return_values.into_iter().map(|(b, _)| b).collect()),
        Err(_) => Outcome::Err,
    }
}

// ---------------------------------------------------------------------------
// Fuzzing differential. Because the old v3 VM is a ground-truth oracle, the
// mutation need NOT preserve semantics -- any mutant both VMs verify+execute
// must yield the same result, whatever it is. A disagreement (different return
// bytes, one executes while the other aborts, or a panic in one) means one VM
// is wrong; since v3 is the proven one, that is a new-VM miscompilation. Both
// VMs run under the step-bounded meter, so non-terminating mutants abort
// (OUT_OF_GAS) in both instead of hanging.
// ---------------------------------------------------------------------------

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

fn locate_run_def(modules: &[CompiledModule]) -> (usize, usize) {
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

/// Apply one arbitrary edit to `run`'s instruction stream (no offset fixup: we
/// are not preserving semantics, only producing a mutant both VMs must agree on
/// or reject).
fn mutate(module: &mut CompiledModule, di: usize, u: &mut Unstructured, rng: &mut Rng) {
    let Some(cu) = module.function_defs[di].code.as_mut() else {
        return;
    };
    if cu.code.is_empty() {
        return;
    }
    let len = cu.code.len();
    let at = (rng.next_u64() as usize) % len;
    match rng.next_u64() % 4 {
        0 => {
            if let Ok(instr) = Bytecode::arbitrary(u) {
                cu.code[at] = instr;
            }
        }
        1 => {
            if let Ok(instr) = Bytecode::arbitrary(u) {
                cu.code.insert(at, instr);
            }
        }
        2 => {
            cu.code.remove(at);
        }
        _ => {
            let b = (rng.next_u64() as usize) % len;
            cu.code.swap(at, b);
        }
    }
}

#[test]
#[ignore = "long fuzz campaign; run with --release --features \"fuzzing testing\""]
fn differential_fuzz_new_vs_old() {
    const ITERS_PER_SEED: usize = 30_000;
    let mut rng = Rng(0xD1FF_0FF5_1234_9999);

    let prev = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));

    let mut findings: Vec<String> = Vec::new();
    let (mut both_ran, mut skipped) = (0usize, 0usize);

    'seeds: for (name, src) in SEEDS {
        let seed = compile(src);
        let (_mi, di) = locate_run_def(&seed);

        for i in 0..ITERS_PER_SEED {
            let nbytes = 4 + (rng.next_u64() % 24) as usize;
            let buf: Vec<u8> = (0..nbytes).map(|_| rng.next_u64() as u8).collect();
            let mut u = Unstructured::new(&buf);

            let mut m = seed.clone();
            let n_muts = 1 + (rng.next_u64() % 2) as usize;
            for _ in 0..n_muts {
                let (mi, _) = locate_run_def(&m);
                mutate(&mut m[mi], di, &mut u, &mut rng);
            }

            let m2 = m.clone();
            let new = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run_new(&m2)));
            let old = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run_old(&m)));

            match (new, old) {
                (Ok(Outcome::Ok(a)), Ok(Outcome::Ok(b))) => {
                    both_ran += 1;
                    if a != b {
                        findings.push(format!("[{name} #{i}] DIVERGENCE new={a:?} old={b:?}"));
                    }
                }
                (Ok(Outcome::Err), Ok(Outcome::Err)) => both_ran += 1,
                (Ok(Outcome::Ok(_)), Ok(Outcome::Err))
                | (Ok(Outcome::Err), Ok(Outcome::Ok(_))) => {
                    findings.push(format!("[{name} #{i}] DIVERGENCE one-Ok-one-abort"));
                }
                (Err(_), Ok(Outcome::Ok(_) | Outcome::Err))
                | (Ok(Outcome::Ok(_) | Outcome::Err), Err(_)) => {
                    findings.push(format!("[{name} #{i}] PANIC in one VM only"));
                }
                _ => skipped += 1,
            }
            if findings.len() > 20 {
                break 'seeds;
            }
        }
    }

    std::panic::set_hook(prev);

    if !findings.is_empty() {
        panic!(
            "CROSS-VERSION FUZZ DIVERGENCE ({} finding(s)) -- new VM disagrees with \
             proven v3 VM (consensus-fork / miscompilation class):\n{}",
            findings.len(),
            findings.join("\n")
        );
    }

    eprintln!(
        "differential_fuzz_new_vs_old: {both_ran} mutants executed equivalently on both VMs, \
         {skipped} skipped (acceptance/both-reject), no divergence"
    );
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
