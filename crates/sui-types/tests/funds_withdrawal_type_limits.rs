// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use move_core_types::language_storage::TypeTag;
use sui_protocol_config::ProtocolConfig;
use sui_types::{
    base_types::{SuiAddress, random_object_ref},
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{
        Command, FundsWithdrawalArg, ProgrammableTransaction, TransactionData,
        TransactionDataAPI, TxValidityCheckContext,
    },
};

fn nested_vector_type(depth: u64) -> TypeTag {
    let mut ty = TypeTag::U8;
    for _ in 0..depth {
        ty = TypeTag::Vector(Box::new(ty));
    }
    ty
}

fn tx_with_withdrawal(type_tag: TypeTag) -> TransactionData {
    let mut ptb = ProgrammableTransactionBuilder::new();
    ptb.funds_withdrawal(FundsWithdrawalArg::balance_from_sender(1, type_tag))
        .unwrap();

    TransactionData::new_programmable(
        SuiAddress::random_for_testing_only(),
        vec![random_object_ref()],
        ptb.finish(),
        1_000_000,
        1_000,
    )
}

fn tx_with_make_move_vec(type_tag: TypeTag) -> TransactionData {
    let pt = ProgrammableTransaction {
        inputs: vec![],
        commands: vec![Command::make_move_vec(Some(type_tag), vec![])],
    };

    TransactionData::new_programmable(
        SuiAddress::random_for_testing_only(),
        vec![random_object_ref()],
        pt,
        1_000_000,
        1_000,
    )
}

#[test]
fn funds_withdrawal_bypasses_type_argument_depth_limit() {
    let config = ProtocolConfig::get_for_max_version_UNSAFE();
    let context = TxValidityCheckContext::from_cfg_for_testing(&config);
    let excessive_depth = config.max_type_argument_depth() + 8;
    let deep_type = nested_vector_type(excessive_depth);

    // Control: the normal TypeInput path enforces max_type_argument_depth.
    let ordinary = tx_with_make_move_vec(deep_type.clone());
    assert!(
        ordinary.validity_check(&context).is_err(),
        "ordinary PTB type inputs must reject depth {excessive_depth}"
    );

    // Bug: FundsWithdrawalArg stores a raw TypeTag and its validity path does not
    // call type_input_validity_check, so the same excessive type passes.
    let withdrawal = tx_with_withdrawal(deep_type);
    assert!(
        withdrawal.validity_check(&context).is_ok(),
        "withdrawal unexpectedly enforced max_type_argument_depth"
    );
}
