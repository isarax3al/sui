// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Structured fuzzer for the deep bytecode-verifier passes (control-flow, stack,
//! locals, type safety, reference safety).
//!
//! Byte-mutation fuzzing mostly exercises the deserializer. To reach the
//! algorithmic verifier passes we instead generate a structurally-valid module
//! skeleton and fill its single function with an `arbitrary`-generated body
//! (`Vec<Bytecode>`) plus arbitrary parameter/return signatures and struct
//! abilities. This is the in-process, `cargo test` equivalent of the existing
//! `bytecode-verifier-libfuzzer` "mixed" target. A panic (not an `Err`) is a
//! verifier crash: modules are published permissionlessly, so it is a remote DoS.

#![cfg(test)]

use arbitrary::{Arbitrary, Unstructured};
use move_binary_format::file_format::{
    AbilitySet, Bytecode, CodeUnit, Constant, DatatypeHandle, DatatypeHandleIndex,
    DatatypeTyParameter, FieldDefinition, FunctionDefinition, FunctionHandle, FunctionHandleIndex,
    IdentifierIndex, ModuleHandleIndex, Signature, SignatureIndex, SignatureToken,
    SignatureToken::{Address, Bool},
    StructDefinition, StructFieldInformation, TypeSignature, Visibility, empty_module,
};
use move_core_types::{account_address::AccountAddress, identifier::Identifier};
use std::panic::{self, AssertUnwindSafe};
use std::str::FromStr;

#[derive(Arbitrary, Debug)]
struct Mixed {
    code: Vec<Bytecode>,
    abilities: AbilitySet,
    param_types: Vec<SignatureToken>,
    return_type: Option<SignatureToken>,
}

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

/// Build the same module skeleton as the libfuzzer "mixed" target and run the
/// full unmetered verifier on it.
fn verify_mixed(mix: Mixed) {
    let mut module = empty_module();
    module.version = 5;

    module.datatype_handles.push(DatatypeHandle {
        module: ModuleHandleIndex(0),
        name: IdentifierIndex(1),
        abilities: mix.abilities,
        type_parameters: vec![],
    });

    module.function_handles.push(FunctionHandle {
        module: ModuleHandleIndex(0),
        name: IdentifierIndex(2),
        parameters: SignatureIndex(0),
        return_: SignatureIndex(1),
        type_parameters: vec![],
    });

    module.signatures.pop();
    module.signatures.push(Signature(mix.param_types));
    module.signatures.push(Signature(
        mix.return_type.map(|s| vec![s]).unwrap_or_default(),
    ));
    module
        .signatures
        .push(Signature(vec![Address, Bool, Address]));

    module.identifiers.extend(vec![
        Identifier::from_str("zf_hello_world").unwrap(),
        Identifier::from_str("awldFnU18mlDKQfh6qNfBGx8X").unwrap(),
        Identifier::from_str("aQPwJNHyAHpvJ").unwrap(),
        Identifier::from_str("aT7ZphKTrKcYCwCebJySrmrKlckmnL5").unwrap(),
        Identifier::from_str("arYpsFa2fvrpPJ").unwrap(),
    ]);
    module.address_identifiers.push(AccountAddress::random());

    module.constant_pool.push(Constant {
        type_: Address,
        data: AccountAddress::ZERO.into_bytes().to_vec(),
    });

    module.struct_defs.push(StructDefinition {
        struct_handle: DatatypeHandleIndex(0),
        field_information: StructFieldInformation::Declared(vec![FieldDefinition {
            name: IdentifierIndex::new(3),
            signature: TypeSignature(Address),
        }]),
    });

    module.function_defs.push(FunctionDefinition {
        code: Some(CodeUnit {
            code: mix.code,
            locals: SignatureIndex(0),
            jump_tables: vec![],
        }),
        function: FunctionHandleIndex(0),
        visibility: Visibility::Public,
        is_entry: false,
        acquires_global_resources: vec![],
    });

    let _ = crate::verifier::verify_module_unmetered(&module);
}

fn build_module(mix: Mixed) -> move_binary_format::CompiledModule {
    let mut module = empty_module();
    module.version = 5;
    module.datatype_handles.push(DatatypeHandle {
        module: ModuleHandleIndex(0),
        name: IdentifierIndex(1),
        abilities: mix.abilities,
        type_parameters: vec![],
    });
    module.function_handles.push(FunctionHandle {
        module: ModuleHandleIndex(0),
        name: IdentifierIndex(2),
        parameters: SignatureIndex(0),
        return_: SignatureIndex(1),
        type_parameters: vec![],
    });
    module.signatures.pop();
    module.signatures.push(Signature(mix.param_types));
    module.signatures.push(Signature(
        mix.return_type.map(|s| vec![s]).unwrap_or_default(),
    ));
    module
        .signatures
        .push(Signature(vec![Address, Bool, Address]));
    module.identifiers.extend(vec![
        Identifier::from_str("zf_hello_world").unwrap(),
        Identifier::from_str("awldFnU18mlDKQfh6qNfBGx8X").unwrap(),
        Identifier::from_str("aQPwJNHyAHpvJ").unwrap(),
        Identifier::from_str("aT7ZphKTrKcYCwCebJySrmrKlckmnL5").unwrap(),
        Identifier::from_str("arYpsFa2fvrpPJ").unwrap(),
    ]);
    module.address_identifiers.push(AccountAddress::random());
    module.constant_pool.push(Constant {
        type_: Address,
        data: AccountAddress::ZERO.into_bytes().to_vec(),
    });
    module.struct_defs.push(StructDefinition {
        struct_handle: DatatypeHandleIndex(0),
        field_information: StructFieldInformation::Declared(vec![FieldDefinition {
            name: IdentifierIndex::new(3),
            signature: TypeSignature(Address),
        }]),
    });
    module.function_defs.push(FunctionDefinition {
        code: Some(CodeUnit {
            code: mix.code,
            locals: SignatureIndex(0),
            jump_tables: vec![],
        }),
        function: FunctionHandleIndex(0),
        visibility: Visibility::Public,
        is_entry: false,
        acquires_global_resources: vec![],
    });
    module
}

const REPRO_ENTROPY: &str = "4bb724f0f75c5e786a64a04db300e08d9e4fcbd80bebe2090d61878c3bdb88d3782a6c4666fc6bb1b22d2bf7fa55bbf07789de591b3b6dbf4e44d6bb780ea2d3da59133bfbe0d5e6c3f6e5d22fe96c540a787c22be117f152bfbb66f834e1cca9dfa09fd16a2c9f8b9420c1a6abecf";

fn decode_hex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

/// Reachability check: is the panicking module producible by the deserializer?
/// If serialize -> deserialize succeeds and the DESERIALIZED module still panics
/// on verify, the crash is reachable from permissionless publication (real).
/// If deserialize rejects it, the direct-build panic is a test artifact.
#[test]
fn repro_codeunit_panic_reachability() {
    let buf = decode_hex(REPRO_ENTROPY);
    let mut u = Unstructured::new(&buf);
    let mix = Mixed::arbitrary(&mut u).expect("entropy rebuilds Mixed");
    let module = build_module(mix);
    println!("=== direct module code = {:?}", module.function_defs[0].code);

    // Does it serialize?
    let mut bytes = vec![];
    match module.serialize_with_version(
        move_binary_format::file_format_common::VERSION_MAX,
        &mut bytes,
    ) {
        Ok(()) => println!("serialize: OK ({} bytes)", bytes.len()),
        Err(e) => {
            println!("serialize: FAILED ({e:?}) -> direct-build module is not a real on-chain module");
            return;
        }
    }

    // Does it deserialize back?
    match move_binary_format::CompiledModule::deserialize_with_defaults(&bytes) {
        Ok(m) => {
            println!("deserialize: OK -> module IS reachable via publication");
            // Now verify the DESERIALIZED (production-shaped) module.
            let res = panic::catch_unwind(AssertUnwindSafe(|| {
                let _ = crate::verifier::verify_module_unmetered(&m);
            }));
            println!(
                "verify(deserialized): {}",
                if res.is_err() { "PANIC (REACHABLE crash)" } else { "returned normally" }
            );
        }
        Err(e) => {
            println!("deserialize: REJECTED ({e:?}) -> direct-build panic is a TEST ARTIFACT (deserializer would reject before verify)");
        }
    }
}

/// Capture the panic location/message by letting it propagate.
#[test]
#[ignore = "run explicitly to see the raw panic + backtrace"]
fn repro_codeunit_panic_raw() {
    let buf = decode_hex(REPRO_ENTROPY);
    let mut u = Unstructured::new(&buf);
    let mix = Mixed::arbitrary(&mut u).expect("entropy rebuilds Mixed");
    verify_mixed(mix); // no catch_unwind: real panic surfaces
}

/// Long-running fuzz campaign. MUST be run with `--release`:
/// `cargo test --release -p move-bytecode-verifier fuzz_codeunit_verifier_no_panic -- --ignored`.
/// In debug builds `safe_assert!`/`debug_assert!` inside the verifier panic by
/// design (they return `Err` in release, which is what mainnet runs), so a debug
/// run reports those benign-in-production asserts as panics. Only a panic under
/// `--release` indicates a real remote-crash candidate.
#[test]
#[ignore = "long fuzz campaign; run with --release (debug-only asserts panic otherwise)"]
fn fuzz_codeunit_verifier_no_panic() {
    const ITERATIONS: usize = 3_000_000;
    let mut rng = Rng(0xC0DE_FACE_1234_0001);

    let prev_hook = panic::take_hook();
    panic::set_hook(Box::new(|_| {}));

    let mut failure: Option<(usize, Vec<u8>)> = None;
    let mut reached = 0usize;
    for i in 0..ITERATIONS {
        // Random-length entropy buffer feeding the Arbitrary generator.
        let len = (rng.next_u64() % 512) as usize;
        let buf: Vec<u8> = (0..len).map(|_| rng.next_u64() as u8).collect();

        let mut u = Unstructured::new(&buf);
        let mix = match Mixed::arbitrary(&mut u) {
            Ok(m) => m,
            Err(_) => continue, // not enough entropy for a full struct
        };
        reached += 1;

        let res = panic::catch_unwind(AssertUnwindSafe(|| verify_mixed(mix)));
        if res.is_err() {
            failure = Some((i, buf));
            break;
        }
    }

    panic::set_hook(prev_hook);

    if let Some((i, buf)) = failure {
        let hex: String = buf.iter().map(|b| format!("{:02x}", b)).collect();
        panic!(
            "VERIFIER PANIC at iteration {i} (seed=0xC0DE_FACE_1234_0001)\n\
             entropy ({} bytes) = {hex}\n",
            buf.len(),
        );
    }

    eprintln!(
        "fuzz_codeunit_verifier_no_panic: {ITERATIONS} iterations, {reached} reached verifier, no panic"
    );
}

// ---------------------------------------------------------------------------
// Generics-aware harness.
//
// The `Mixed` skeleton above declares zero type parameters on both the struct
// and the function handle. Any `SignatureToken::TypeParameter(n)` or
// `DatatypeInstantiation` an arbitrary signature produces is therefore
// out-of-bounds and rejected by the early bounds checker, so the *generic*
// branches of the type-safety and reference-safety passes are never reached.
//
// `MixedGeneric` instead declares a fuzzer-chosen number of type parameters on
// both the datatype and the function, so arbitrary generic tokens are in-bounds
// and flow into the "paranoid" instantiation type checker and the borrow-graph
// join over generic references -- the region where a verifier type-confusion
// bypass (accepting an ill-typed generic module = memory-unsafe on-chain
// execution) would live. A panic here is a real remote-crash candidate; an
// accepted-but-ill-typed module is a far more serious soundness break.
#[derive(Arbitrary, Debug)]
struct MixedGeneric {
    code: Vec<Bytecode>,
    struct_abilities: AbilitySet,
    // Constraints for each declared datatype type parameter (also fixes their count).
    struct_ty_params: Vec<AbilitySet>,
    struct_ty_params_phantom: Vec<bool>,
    // Constraints for each declared function type parameter.
    fun_ty_params: Vec<AbilitySet>,
    param_types: Vec<SignatureToken>,
    return_type: Option<SignatureToken>,
    // Field type of the single struct field -- may itself reference a type parameter.
    field_type: SignatureToken,
    // Local variable types for the function body.
    locals: Vec<SignatureToken>,
}

fn verify_mixed_generic(mix: MixedGeneric) {
    let mut module = empty_module();
    module.version = 5;

    // Cap declared type-parameter counts so index space stays small enough that
    // arbitrary TypeParameter(n) tokens frequently land in-bounds.
    let struct_tps: Vec<DatatypeTyParameter> = mix
        .struct_ty_params
        .into_iter()
        .take(4)
        .enumerate()
        .map(|(i, constraints)| DatatypeTyParameter {
            constraints,
            is_phantom: mix.struct_ty_params_phantom.get(i).copied().unwrap_or(false),
        })
        .collect();
    let fun_tps: Vec<AbilitySet> = mix.fun_ty_params.into_iter().take(4).collect();

    module.datatype_handles.push(DatatypeHandle {
        module: ModuleHandleIndex(0),
        name: IdentifierIndex(1),
        abilities: mix.struct_abilities,
        type_parameters: struct_tps,
    });

    module.function_handles.push(FunctionHandle {
        module: ModuleHandleIndex(0),
        name: IdentifierIndex(2),
        parameters: SignatureIndex(0),
        return_: SignatureIndex(1),
        type_parameters: fun_tps,
    });

    module.signatures.pop();
    module.signatures.push(Signature(mix.param_types)); // index 0: params
    module.signatures.push(Signature(
        mix.return_type.map(|s| vec![s]).unwrap_or_default(),
    )); // index 1: return
    module.signatures.push(Signature(mix.locals)); // index 2: locals

    module.identifiers.extend(vec![
        Identifier::from_str("zf_hello_world").unwrap(),
        Identifier::from_str("awldFnU18mlDKQfh6qNfBGx8X").unwrap(),
        Identifier::from_str("aQPwJNHyAHpvJ").unwrap(),
        Identifier::from_str("aT7ZphKTrKcYCwCebJySrmrKlckmnL5").unwrap(),
        Identifier::from_str("arYpsFa2fvrpPJ").unwrap(),
    ]);
    module.address_identifiers.push(AccountAddress::random());

    module.constant_pool.push(Constant {
        type_: Address,
        data: AccountAddress::ZERO.into_bytes().to_vec(),
    });

    module.struct_defs.push(StructDefinition {
        struct_handle: DatatypeHandleIndex(0),
        field_information: StructFieldInformation::Declared(vec![FieldDefinition {
            name: IdentifierIndex::new(3),
            signature: TypeSignature(mix.field_type),
        }]),
    });

    module.function_defs.push(FunctionDefinition {
        code: Some(CodeUnit {
            code: mix.code,
            locals: SignatureIndex(2),
            jump_tables: vec![],
        }),
        function: FunctionHandleIndex(0),
        visibility: Visibility::Public,
        is_entry: false,
        acquires_global_resources: vec![],
    });

    let _ = crate::verifier::verify_module_unmetered(&module);
}

/// Long-running generics fuzz campaign. MUST be run with `--release` for the same
/// reason as `fuzz_codeunit_verifier_no_panic` (debug-only asserts in the verifier
/// panic by design and would produce benign-in-production false positives):
/// `cargo test --release -p move-bytecode-verifier fuzz_generic_verifier_no_panic -- --ignored`.
#[test]
#[ignore = "long fuzz campaign; run with --release (debug-only asserts panic otherwise)"]
fn fuzz_generic_verifier_no_panic() {
    const ITERATIONS: usize = 5_000_000;
    let mut rng = Rng(0x6E4E_1C5A_0F00_D00D);

    let prev_hook = panic::take_hook();
    panic::set_hook(Box::new(|_| {}));

    let mut failure: Option<(usize, Vec<u8>)> = None;
    let mut reached = 0usize;
    for i in 0..ITERATIONS {
        // Larger entropy budget: MixedGeneric has more fields to fill than Mixed.
        let len = (rng.next_u64() % 1024) as usize;
        let buf: Vec<u8> = (0..len).map(|_| rng.next_u64() as u8).collect();

        let mut u = Unstructured::new(&buf);
        let mix = match MixedGeneric::arbitrary(&mut u) {
            Ok(m) => m,
            Err(_) => continue,
        };
        reached += 1;

        let res = panic::catch_unwind(AssertUnwindSafe(|| verify_mixed_generic(mix)));
        if res.is_err() {
            failure = Some((i, buf));
            break;
        }
    }

    panic::set_hook(prev_hook);

    if let Some((i, buf)) = failure {
        let hex: String = buf.iter().map(|b| format!("{:02x}", b)).collect();
        panic!(
            "GENERIC VERIFIER PANIC at iteration {i} (seed=0x6E4E_1C5A_0F00_D00D)\n\
             entropy ({} bytes) = {hex}\n",
            buf.len(),
        );
    }

    eprintln!(
        "fuzz_generic_verifier_no_panic: {ITERATIONS} iterations, {reached} reached verifier, no panic"
    );
}

/// Reproduce a specific generic-harness failure from its hex entropy. Paste the
/// hex printed by the campaign into `entropy` and run explicitly.
#[test]
#[ignore = "manual repro; paste failing entropy first"]
fn repro_generic_panic_raw() {
    let entropy = ""; // <- paste failing hex here
    if entropy.is_empty() {
        eprintln!("no entropy set; nothing to reproduce");
        return;
    }
    let buf = decode_hex(entropy);
    let mut u = Unstructured::new(&buf);
    let mix = MixedGeneric::arbitrary(&mut u).expect("entropy rebuilds MixedGeneric");
    verify_mixed_generic(mix);
}
