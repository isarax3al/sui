// Copyright (c) The Move Contributors
// SPDX-License-Identifier: Apache-2.0

use move_core_types::account_address::AccountAddress;
use move_vm_types_v3::values::{Locals, Reference, Struct, StructRef, VMValueCast, Value};

fn make_struct(value: AccountAddress) -> Value {
    Value::struct_(Struct::pack(vec![Value::address(value)]))
}

fn read_struct_field(reference: Value) -> AccountAddress {
    let struct_ref: StructRef = VMValueCast::cast(reference).expect("struct reference");
    let field_ref: Reference =
        VMValueCast::cast(struct_ref.borrow_field(0).expect("field borrow")).expect("field ref");
    VMValueCast::cast(field_ref.read_ref().expect("read ref")).expect("address value")
}

fn main() {
    let old = AccountAddress::ONE;
    let new = AccountAddress::from_hex_literal("0x2").unwrap();

    // Mirrors Sui when disable_invariant_violation_check_in_swap_loc=true.
    let mut unchecked = Locals::new(1);
    unchecked
        .store_loc(0, make_struct(old), false)
        .expect("initial store");
    let stale_ref = unchecked.borrow_loc(0).expect("borrow old struct");
    unchecked
        .store_loc(0, make_struct(new), false)
        .expect("unchecked replacement");
    let observed = read_struct_field(stale_ref);
    println!(
        "RUNTIME_CASE=struct_direct_alias_swap_guard_disabled STORE=ACCEPT OBSERVED={} EXPECTED_OLD={} EXPECTED_NEW={}",
        observed, old, new
    );

    // VM default behavior with the invariant guard enabled.
    let mut checked = Locals::new(1);
    checked
        .store_loc(0, make_struct(old), true)
        .expect("initial checked store");
    let live_ref = checked.borrow_loc(0).expect("borrow checked struct");
    let checked_result = checked.store_loc(0, make_struct(new), true);
    println!(
        "RUNTIME_CASE=struct_direct_alias_swap_guard_enabled STORE={} STATUS={:?}",
        if checked_result.is_ok() { "ACCEPT" } else { "REJECT" },
        checked_result.as_ref().err().map(|e| e.major_status())
    );
    drop(live_ref);

    // Primitive local references are indexed into the Locals container and therefore follow the slot.
    let mut primitive = Locals::new(1);
    primitive
        .store_loc(0, Value::address(old), false)
        .expect("initial primitive store");
    let slot_ref: Reference =
        VMValueCast::cast(primitive.borrow_loc(0).expect("borrow primitive")).expect("reference");
    primitive
        .store_loc(0, Value::address(new), false)
        .expect("primitive replacement");
    let primitive_observed: AccountAddress =
        VMValueCast::cast(slot_ref.read_ref().expect("read primitive ref")).expect("address");
    println!(
        "RUNTIME_CASE=primitive_direct_alias_swap_guard_disabled STORE=ACCEPT OBSERVED={} EXPECTED_NEW={}",
        primitive_observed, new
    );
}
