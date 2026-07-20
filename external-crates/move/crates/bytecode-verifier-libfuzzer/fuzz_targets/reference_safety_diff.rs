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
use move_bytecode_verifier::verify_module_with_config_unmetered;
use move_core_types::{account_address::AccountAddress, identifier::Identifier, vm_status::StatusCode};
use move_vm_config::verifier::VerifierConfig;
use std::str::FromStr;

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

fuzz_target!(|code_unit: CodeUnit| {
    let module = module_from_code_unit(code_unit);

    let legacy = verify_module_with_config_unmetered(&config(false), &module);
    let regex = verify_module_with_config_unmetered(&config(true), &module);

    // The migration-risk direction is legacy rejecting while regex accepts. Complexity failures
    // are excluded because they are resource-limit differences, not evidence of unsoundness.
    if let (Err(legacy_err), Ok(())) = (legacy, regex) {
        let status = legacy_err.major_status();
        if !matches!(
            status,
            StatusCode::CONSTRAINT_NOT_SATISFIED | StatusCode::PROGRAM_TOO_COMPLEX
        ) {
            panic!(
                "dangerous reference-safety divergence: legacy rejected with {status:?}, regex accepted; module={module:#?}"
            );
        }
    }
});
