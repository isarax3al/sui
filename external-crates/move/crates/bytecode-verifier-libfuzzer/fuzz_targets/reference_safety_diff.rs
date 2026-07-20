// Copyright (c) The Move Contributors
// SPDX-License-Identifier: Apache-2.0

#![no_main]

use libfuzzer_sys::fuzz_target;
use move_binary_format::file_format::{
    AbilitySet, CodeUnit, Constant, DatatypeHandle, DatatypeHandleIndex, FieldDefinition,
    FunctionDefinition, FunctionHandle, FunctionHandleIndex, IdentifierIndex, ModuleHandleIndex,
    Signature, SignatureIndex,
    SignatureToken::{Address, Bool, U64, U128},
    StructDefinition, StructFieldInformation, TypeSignature, Visibility, empty_module,
};
use move_bytecode_verifier::{
    ability_cache::AbilityCache,
    code_unit_verifier,
    verifier::verify_module_with_config_metered_up_to_code_units,
};
use move_bytecode_verifier_meter::dummy::DummyMeter;
use move_core_types::{
    account_address::AccountAddress, identifier::Identifier, vm_status::StatusCode,
};
use move_vm_config::verifier::VerifierConfig;
use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    str::FromStr,
    sync::{
        Once,
        atomic::{AtomicU64, Ordering},
    },
};

static INSTALL_QUIET_PANIC_HOOK: Once = Once::new();
static TOTAL_INPUTS: AtomicU64 = AtomicU64::new(0);
static COMMON_PREFLIGHT_OK: AtomicU64 = AtomicU64::new(0);
static BOTH_CODE_UNIT_RUNS_COMPLETED: AtomicU64 = AtomicU64::new(0);
static LEGACY_ACCEPTS: AtomicU64 = AtomicU64::new(0);
static REGEX_ACCEPTS: AtomicU64 = AtomicU64::new(0);
static EXPECTED_DIRECTION_DIFFERENCES: AtomicU64 = AtomicU64::new(0);
static DANGEROUS_DIRECTION_DIFFERENCES: AtomicU64 = AtomicU64::new(0);

fn module_from_code_unit(code_unit: CodeUnit) -> move_binary_format::file_format::CompiledModule {
    // Keep this module shape aligned with the existing code_unit fuzz target. The only fuzzed
    // component is the CodeUnit, while all referenced tables are deterministic and in-bounds for
    // the common small indices libFuzzer converges on.
    let mut module = empty_module();
    module.version = 5;

    module.datatype_handles.push(DatatypeHandle {
        module: ModuleHandleIndex(0),
        name: IdentifierIndex(1),
        abilities: AbilitySet::ALL,
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
    module.signatures.push(Signature(vec![
        Address, U64, Address, Address, U128, Address, U64, U64, U64,
    ]));
    module.signatures.push(Signature(vec![]));
    module
        .signatures
        .push(Signature(vec![Address, Bool, Address]));

    module.identifiers.extend(
        vec![
            Identifier::from_str("zf_hello_world").unwrap(),
            Identifier::from_str("awldFnU18mlDKQfh6qNfBGx8X").unwrap(),
            Identifier::from_str("aQPwJNHyAHpvJ").unwrap(),
            Identifier::from_str("aT7ZphKTrKcYCwCebJySrmrKlckmnL5").unwrap(),
            Identifier::from_str("arYpsFa2fvrpPJ").unwrap(),
        ]
        .into_iter(),
    );
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
        code: Some(code_unit),
        function: FunctionHandleIndex(0),
        visibility: Visibility::Public,
        is_entry: false,
        acquires_global_resources: vec![],
    });

    module
}

fn config(use_regex: bool) -> VerifierConfig {
    let mut config = VerifierConfig::default();
    config.switch_to_regex_reference_safety = use_regex;
    // The differential harness compares the implementations directly. Running the shadow sanity
    // checker in the legacy arm would add a third result and obscure the dangerous direction.
    config.sanity_check_with_regex_reference_safety = None;
    config
}

fn print_stats(total: u64) {
    if total % 100_000 != 0 {
        return;
    }
    eprintln!(
        "DIFF_FUZZ_STATS total={} preflight_ok={} code_unit_both_completed={} legacy_accepts={} regex_accepts={} expected_direction={} dangerous_direction={}",
        total,
        COMMON_PREFLIGHT_OK.load(Ordering::Relaxed),
        BOTH_CODE_UNIT_RUNS_COMPLETED.load(Ordering::Relaxed),
        LEGACY_ACCEPTS.load(Ordering::Relaxed),
        REGEX_ACCEPTS.load(Ordering::Relaxed),
        EXPECTED_DIRECTION_DIFFERENCES.load(Ordering::Relaxed),
        DANGEROUS_DIRECTION_DIFFERENCES.load(Ordering::Relaxed),
    );
}

fuzz_target!(|code_unit: CodeUnit| {
    INSTALL_QUIET_PANIC_HOOK.call_once(|| std::panic::set_hook(Box::new(|_| {})));

    let total = TOTAL_INPUTS.fetch_add(1, Ordering::Relaxed) + 1;
    print_stats(total);

    let module = module_from_code_unit(code_unit);

    // Run all module-level checks shared by both implementations once. Inputs that cannot reach the
    // code-unit verifier are not useful for this differential campaign.
    let common_preflight = catch_unwind(AssertUnwindSafe(|| {
        let mut ability_cache = AbilityCache::new(&module);
        verify_module_with_config_metered_up_to_code_units(
            &config(false),
            &module,
            &mut ability_cache,
            &mut DummyMeter,
        )
    }));
    let Ok(Ok(())) = common_preflight else {
        return;
    };
    COMMON_PREFLIGHT_OK.fetch_add(1, Ordering::Relaxed);

    // Now compare the same code unit under identical configuration except for the selected
    // reference-safety implementation.
    let legacy = catch_unwind(AssertUnwindSafe(|| {
        let mut ability_cache = AbilityCache::new(&module);
        code_unit_verifier::verify_module(
            &config(false),
            &module,
            &mut ability_cache,
            &mut DummyMeter,
        )
    }));
    let regex = catch_unwind(AssertUnwindSafe(|| {
        let mut ability_cache = AbilityCache::new(&module);
        code_unit_verifier::verify_module(
            &config(true),
            &module,
            &mut ability_cache,
            &mut DummyMeter,
        )
    }));

    let (Ok(legacy), Ok(regex)) = (legacy, regex) else {
        return;
    };
    BOTH_CODE_UNIT_RUNS_COMPLETED.fetch_add(1, Ordering::Relaxed);

    if legacy.is_ok() {
        LEGACY_ACCEPTS.fetch_add(1, Ordering::Relaxed);
    }
    if regex.is_ok() {
        REGEX_ACCEPTS.fetch_add(1, Ordering::Relaxed);
    }

    match (legacy, regex) {
        (Ok(()), Err(_)) => {
            // This is the direction the production sanity assertion is designed to catch.
            EXPECTED_DIRECTION_DIFFERENCES.fetch_add(1, Ordering::Relaxed);
        }
        (Err(legacy_err), Ok(())) => {
            let status = legacy_err.major_status();
            if matches!(
                status,
                StatusCode::CONSTRAINT_NOT_SATISFIED | StatusCode::PROGRAM_TOO_COMPLEX
            ) {
                return;
            }

            DANGEROUS_DIRECTION_DIFFERENCES.fetch_add(1, Ordering::Relaxed);
            eprintln!(
                "DANGEROUS_REFERENCE_SAFETY_DIVERGENCE legacy_status={status:?} module={module:#?}"
            );
            panic!("legacy reference safety rejected while regex reference safety accepted");
        }
        (Ok(()), Ok(())) | (Err(_), Err(_)) => {}
    }
});
