// Copyright (c) The Move Contributors
// SPDX-License-Identifier: Apache-2.0

use move_binary_format::file_format::{
    AbilitySet, AddressIdentifierIndex, Bytecode, CodeUnit, Constant, ConstantPoolIndex,
    DatatypeHandle, DatatypeHandleIndex, FieldDefinition, FieldHandle, FieldHandleIndex,
    FunctionDefinition, FunctionHandle, FunctionHandleIndex, IdentifierIndex, ModuleHandle,
    ModuleHandleIndex, Signature, SignatureIndex,
    SignatureToken::{Address, Datatype, MutableReference, Reference},
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

fn config(use_regex: bool) -> VerifierConfig {
    let mut config = VerifierConfig::default();
    config.switch_to_regex_reference_safety = use_regex;
    config.sanity_check_with_regex_reference_safety = None;
    config
}

fn make_module(code: Vec<Bytecode>) -> move_binary_format::file_format::CompiledModule {
    let mut module = empty_module();
    module.version = 5;

    // Existing index 0 is the module's own address/name. Add an external module for helper calls.
    module.address_identifiers.push(AccountAddress::ONE);
    module.identifiers.extend([
        Identifier::from_str("main_probe").unwrap(),
        Identifier::from_str("ExternalProbe").unwrap(),
        Identifier::from_str("consume_one_mut").unwrap(),
        Identifier::from_str("consume_two_mut").unwrap(),
    ]);
    module.module_handles.push(ModuleHandle {
        address: AddressIdentifierIndex(1),
        name: IdentifierIndex(2),
    });

    let mut_ref_address = MutableReference(Box::new(Address));
    let imm_ref_address = Reference(Box::new(Address));
    module.signatures = vec![
        Signature(vec![Address]),
        Signature(vec![]),
        // Parameters occupy local index 0. These extra locals occupy indices 1, 2, and 3.
        Signature(vec![
            mut_ref_address.clone(),
            mut_ref_address.clone(),
            imm_ref_address,
        ]),
        Signature(vec![mut_ref_address.clone()]),
        Signature(vec![mut_ref_address.clone(), mut_ref_address]),
    ];

    module.function_handles.push(FunctionHandle {
        module: ModuleHandleIndex(0),
        name: IdentifierIndex(1),
        parameters: SignatureIndex(0),
        return_: SignatureIndex(1),
        type_parameters: vec![],
    });
    module.function_handles.push(FunctionHandle {
        module: ModuleHandleIndex(1),
        name: IdentifierIndex(3),
        parameters: SignatureIndex(3),
        return_: SignatureIndex(1),
        type_parameters: vec![],
    });
    module.function_handles.push(FunctionHandle {
        module: ModuleHandleIndex(1),
        name: IdentifierIndex(4),
        parameters: SignatureIndex(4),
        return_: SignatureIndex(1),
        type_parameters: vec![],
    });

    module.constant_pool.push(Constant {
        type_: Address,
        data: AccountAddress::ZERO.into_bytes().to_vec(),
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

fn make_struct_module(code: Vec<Bytecode>) -> move_binary_format::file_format::CompiledModule {
    let mut module = empty_module();
    module.version = 5;

    // Existing identifier 0 is the module name. Added identifiers are 1=probe, 2=S, 3=f.
    module.identifiers.extend([
        Identifier::from_str("struct_probe").unwrap(),
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

    let struct_ty = Datatype(DatatypeHandleIndex(0));
    let mut_ref_struct = MutableReference(Box::new(struct_ty.clone()));
    let imm_ref_struct = Reference(Box::new(struct_ty.clone()));
    let imm_ref_address = Reference(Box::new(Address));
    let mut_ref_address = MutableReference(Box::new(Address));

    module.signatures = vec![
        Signature(vec![struct_ty]),
        Signature(vec![]),
        // Param is local 0. Extra locals: 1=&mut S, 2=&S, 3=&address, 4=&mut address.
        Signature(vec![
            mut_ref_struct,
            imm_ref_struct,
            imm_ref_address,
            mut_ref_address,
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

fn result_status(result: move_binary_format::errors::VMResult<()>) -> String {
    match result {
        Ok(()) => "ACCEPT".to_string(),
        Err(err) => format!("REJECT({:?})", err.major_status()),
    }
}

fn run_module_case(
    name: &str,
    module: move_binary_format::file_format::CompiledModule,
) {
    let mut preflight_cache = AbilityCache::new(&module);
    let preflight = verify_module_with_config_metered_up_to_code_units(
        &config(false),
        &module,
        &mut preflight_cache,
        &mut DummyMeter,
    );
    if let Err(err) = preflight {
        println!("CASE={name} PREFLIGHT=REJECT({:?})", err.major_status());
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
        "CASE={name} LEGACY={} REGEX={}",
        result_status(legacy),
        result_status(regex)
    );
}

fn run_case(name: &str, code: Vec<Bytecode>) {
    run_module_case(name, make_module(code));
}

fn run_struct_case(name: &str, code: Vec<Bytecode>) {
    run_module_case(name, make_struct_module(code));
}

fn main() {
    use Bytecode::*;

    run_case(
        "dead_mut_plus_imm_alias",
        vec![MutBorrowLoc(0), ImmBorrowLoc(0), Pop, Pop, Ret],
    );

    run_case(
        "write_through_mut_then_read_imm_alias",
        vec![
            MutBorrowLoc(0),
            StLoc(1),
            ImmBorrowLoc(0),
            StLoc(3),
            LdConst(ConstantPoolIndex(0)),
            MoveLoc(1),
            WriteRef,
            MoveLoc(3),
            ReadRef,
            Pop,
            Ret,
        ],
    );

    run_case(
        "two_mut_aliases_sequential_writes",
        vec![
            MutBorrowLoc(0),
            StLoc(1),
            MutBorrowLoc(0),
            StLoc(2),
            LdConst(ConstantPoolIndex(0)),
            MoveLoc(1),
            WriteRef,
            LdConst(ConstantPoolIndex(0)),
            MoveLoc(2),
            WriteRef,
            Ret,
        ],
    );

    run_case(
        "call_with_one_mut_while_second_alias_hidden",
        vec![
            MutBorrowLoc(0),
            StLoc(1),
            MutBorrowLoc(0),
            StLoc(2),
            MoveLoc(1),
            Call(FunctionHandleIndex(1)),
            LdConst(ConstantPoolIndex(0)),
            MoveLoc(2),
            WriteRef,
            Ret,
        ],
    );

    run_case(
        "call_with_both_mut_aliases",
        vec![
            MutBorrowLoc(0),
            StLoc(1),
            MutBorrowLoc(0),
            StLoc(2),
            MoveLoc(1),
            MoveLoc(2),
            Call(FunctionHandleIndex(2)),
            Ret,
        ],
    );

    // Create a root mutable alias first, then derive an immutable field reference through a second
    // root alias. Replacing the whole struct must be rejected while the field reference is alive.
    run_struct_case(
        "mut_root_then_imm_field_then_root_write",
        vec![
            MutBorrowLoc(0),
            StLoc(1),
            ImmBorrowLoc(0),
            ImmBorrowField(FieldHandleIndex(0)),
            StLoc(3),
            LdConst(ConstantPoolIndex(0)),
            Pack(StructDefinitionIndex(0)),
            MoveLoc(1),
            WriteRef,
            MoveLoc(3),
            ReadRef,
            Pop,
            Ret,
        ],
    );

    // Reverse creation order to exercise graph edge propagation in the opposite direction.
    run_struct_case(
        "imm_field_then_mut_root_then_root_write",
        vec![
            ImmBorrowLoc(0),
            ImmBorrowField(FieldHandleIndex(0)),
            StLoc(3),
            MutBorrowLoc(0),
            StLoc(1),
            LdConst(ConstantPoolIndex(0)),
            Pack(StructDefinitionIndex(0)),
            MoveLoc(1),
            WriteRef,
            MoveLoc(3),
            ReadRef,
            Pop,
            Ret,
        ],
    );

    // A mutable field reference is even stronger: overwriting the root must not detach the field
    // while leaving a writable reference to the old value.
    run_struct_case(
        "mut_field_then_second_mut_root_write",
        vec![
            MutBorrowLoc(0),
            MutBorrowField(FieldHandleIndex(0)),
            StLoc(4),
            MutBorrowLoc(0),
            StLoc(1),
            LdConst(ConstantPoolIndex(0)),
            Pack(StructDefinitionIndex(0)),
            MoveLoc(1),
            WriteRef,
            LdConst(ConstantPoolIndex(0)),
            MoveLoc(4),
            WriteRef,
            Ret,
        ],
    );

    // StLoc replaces the local slot directly. A live field reference must prevent this replacement.
    run_struct_case(
        "imm_field_then_stloc_parent",
        vec![
            ImmBorrowLoc(0),
            ImmBorrowField(FieldHandleIndex(0)),
            StLoc(3),
            LdConst(ConstantPoolIndex(0)),
            Pack(StructDefinitionIndex(0)),
            StLoc(0),
            MoveLoc(3),
            ReadRef,
            Pop,
            Ret,
        ],
    );

    run_struct_case(
        "mut_field_then_stloc_parent",
        vec![
            MutBorrowLoc(0),
            MutBorrowField(FieldHandleIndex(0)),
            StLoc(4),
            LdConst(ConstantPoolIndex(0)),
            Pack(StructDefinitionIndex(0)),
            StLoc(0),
            LdConst(ConstantPoolIndex(0)),
            MoveLoc(4),
            WriteRef,
            Ret,
        ],
    );

    // Direct equal aliases are the intended relaxation candidate: replacement may be safe if the
    // reference follows the local slot. This case separates that behavior from stale field refs.
    run_struct_case(
        "direct_imm_alias_then_stloc_parent",
        vec![
            ImmBorrowLoc(0),
            StLoc(2),
            LdConst(ConstantPoolIndex(0)),
            Pack(StructDefinitionIndex(0)),
            StLoc(0),
            MoveLoc(2),
            ImmBorrowField(FieldHandleIndex(0)),
            ReadRef,
            Pop,
            Ret,
        ],
    );
}
