// Copyright (c) The Move Contributors
// SPDX-License-Identifier: Apache-2.0

use move_binary_format::file_format::{
    AbilitySet, Bytecode, CodeUnit, Constant, ConstantPoolIndex, DatatypeHandle,
    DatatypeHandleIndex, FieldDefinition, FieldHandle, FieldHandleIndex, FunctionDefinition,
    FunctionHandle, FunctionHandleIndex, IdentifierIndex, ModuleHandleIndex, Signature,
    SignatureIndex,
    SignatureToken::{Address, Bool, Datatype, MutableReference, Reference},
    StructDefinition, StructDefinitionIndex, StructFieldInformation, TypeSignature, Visibility,
    empty_module,
};
use move_bytecode_verifier::{
    ability_cache::AbilityCache,
    code_unit_verifier,
    verifier::verify_module_with_config_metered_up_to_code_units,
};
use move_bytecode_verifier_meter::dummy::DummyMeter;
use move_core_types::{account_address::AccountAddress, identifier::Identifier};
use move_vm_config::verifier::VerifierConfig;
use std::str::FromStr;

fn config(regex: bool) -> VerifierConfig {
    let mut config = VerifierConfig::default();
    config.switch_to_regex_reference_safety = regex;
    config.sanity_check_with_regex_reference_safety = None;
    config
}

fn module_with_mixed_join(code: Vec<Bytecode>) -> move_binary_format::file_format::CompiledModule {
    let mut module = empty_module();
    module.version = 5;
    module.identifiers.extend([
        Identifier::from_str("join_probe").unwrap(),
        Identifier::from_str("S").unwrap(),
        Identifier::from_str("f").unwrap(),
    ]);

    module.datatype_handles.push(DatatypeHandle {
        module: ModuleHandleIndex(0),
        name: IdentifierIndex(2),
        abilities: AbilitySet::PRIMITIVES,
        type_parameters: vec![],
    });
    module.struct_defs.push(StructDefinition {
        struct_handle: DatatypeHandleIndex(0),
        field_information: StructFieldInformation::Declared(vec![FieldDefinition {
            name: IdentifierIndex(3),
            signature: TypeSignature(Address),
        }]),
    });
    module.field_handles.push(FieldHandle {
        owner: StructDefinitionIndex(0),
        field: 0,
    });

    let s = Datatype(DatatypeHandleIndex(0));
    module.signatures = vec![
        Signature(vec![Bool, s, Address]),
        Signature(vec![]),
        // Parameters are locals 0..2. Extra locals are 3=&address and 4=&mut address.
        Signature(vec![
            Reference(Box::new(Address)),
            MutableReference(Box::new(Address)),
        ]),
    ];
    module.function_handles.push(FunctionHandle {
        module: ModuleHandleIndex(0),
        name: IdentifierIndex(1),
        parameters: SignatureIndex(0),
        return_: SignatureIndex(1),
        type_parameters: vec![],
    });
    module.constant_pool.push(Constant {
        type_: Address,
        data: AccountAddress::ONE.into_bytes().to_vec(),
    });
    module.function_defs.push(FunctionDefinition {
        code: Some(CodeUnit {
            locals: SignatureIndex(2),
            code,
            jump_tables: vec![],
        }),
        function: FunctionHandleIndex(0),
        visibility: Visibility::Public,
        is_entry: false,
        acquires_global_resources: vec![],
    });
    module
}

fn status(result: move_binary_format::errors::VMResult<()>) -> String {
    match result {
        Ok(()) => "ACCEPT".to_string(),
        Err(error) => format!("REJECT({:?})", error.major_status()),
    }
}

fn run(name: &str, code: Vec<Bytecode>) {
    let module = module_with_mixed_join(code);
    let mut preflight_cache = AbilityCache::new(&module);
    if let Err(error) = verify_module_with_config_metered_up_to_code_units(
        &config(false),
        &module,
        &mut preflight_cache,
        &mut DummyMeter,
    ) {
        println!("JOIN_CASE={name} PREFLIGHT=REJECT({:?})", error.major_status());
        return;
    }

    let mut legacy_cache = AbilityCache::new(&module);
    let legacy = code_unit_verifier::verify_module(
        &config(false),
        &module,
        &mut legacy_cache,
        &mut DummyMeter,
    );
    let mut regex_cache = AbilityCache::new(&module);
    let regex = code_unit_verifier::verify_module(
        &config(true),
        &module,
        &mut regex_cache,
        &mut DummyMeter,
    );
    println!(
        "JOIN_CASE={name} LEGACY={} REGEX={}",
        status(legacy),
        status(regex)
    );
}

fn main() {
    use Bytecode::*;

    // At the join, local 3 contains either a descendant of S (true path) or an exact alias of the
    // unrelated address parameter (false path). Replacing S must be rejected because the true path
    // leaves a live field reference into S.
    run(
        "imm_field_or_unrelated_direct_ref_then_replace_parent",
        vec![
            CopyLoc(0),
            BrFalse(6),
            ImmBorrowLoc(1),
            ImmBorrowField(FieldHandleIndex(0)),
            StLoc(3),
            Branch(8),
            ImmBorrowLoc(2),
            StLoc(3),
            LdConst(ConstantPoolIndex(0)),
            Pack(StructDefinitionIndex(0)),
            StLoc(1),
            MoveLoc(3),
            ReadRef,
            Pop,
            Ret,
        ],
    );

    // Same mixed-path join with a mutable reference. If the field path is forgotten, this writes
    // through a detached mutable reference after the parent local was replaced.
    run(
        "mut_field_or_unrelated_direct_ref_then_replace_parent",
        vec![
            CopyLoc(0),
            BrFalse(6),
            MutBorrowLoc(1),
            MutBorrowField(FieldHandleIndex(0)),
            StLoc(4),
            Branch(8),
            MutBorrowLoc(2),
            StLoc(4),
            LdConst(ConstantPoolIndex(0)),
            Pack(StructDefinitionIndex(0)),
            StLoc(1),
            LdConst(ConstantPoolIndex(0)),
            MoveLoc(4),
            WriteRef,
            Ret,
        ],
    );
}
