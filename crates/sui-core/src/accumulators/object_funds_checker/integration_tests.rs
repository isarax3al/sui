// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Testing the integration of the object funds withdraw scheduler with the execution scheduler.

use std::sync::Arc;

use fastcrypto::ed25519::Ed25519KeyPair;
use sui_protocol_config::ProtocolConfig;
use sui_test_transaction_builder::{FundSource, TestTransactionBuilder};
use sui_types::{
    SUI_ACCUMULATOR_ROOT_OBJECT_ID, TypeTag,
    accumulator_root::AccumulatorValue,
    balance::Balance,
    base_types::{ObjectID, ObjectRef, SuiAddress},
    crypto::get_account_key_pair,
    effects::{TransactionEffects, TransactionEffectsAPI},
    executable_transaction::VerifiedExecutableTransaction,
    execution::ExecutionOutput,
    execution_status::{ExecutionErrorKind, ExecutionFailure, ExecutionStatus},
    gas_coin::GAS,
    object::Object,
};

use crate::authority::{
    AuthorityState, ExecutionEnv, authority_per_epoch_store::AuthorityPerEpochStore,
    shared_object_version_manager::AssignedVersions, test_authority_builder::TestAuthorityBuilder,
};

struct TestEnv {
    authority: Arc<AuthorityState>,
    epoch_store: Arc<AuthorityPerEpochStore>,
    sender: SuiAddress,
    keypair: Ed25519KeyPair,
    gas_obj: ObjectID,
    package_id: ObjectID,
    vault_obj: ObjectID,
}

impl TestEnv {
    pub async fn new() -> Self {
        let mut protocol_config = ProtocolConfig::get_for_max_version_UNSAFE();
        protocol_config.enable_accumulators_for_testing();
        protocol_config.create_root_accumulator_object_for_testing();
        protocol_config.set_enable_object_funds_withdraw_for_testing(true);

        let (sender, keypair) = get_account_key_pair();
        let gas_obj = Object::with_owner_for_testing(sender);

        let authority = TestAuthorityBuilder::new()
            .with_protocol_config(protocol_config)
            .with_starting_objects(std::slice::from_ref(&gas_obj))
            .build()
            .await;
        let epoch_store = authority.epoch_store_for_testing().clone();

        let gas = gas_obj.compute_object_reference();
        let rgp = epoch_store.reference_gas_price();
        let tx = TestTransactionBuilder::new(sender, gas, rgp)
            .publish_examples("object_balance")
            .await
            .build();
        let cert = VerifiedExecutableTransaction::new_for_testing(tx, &keypair);
        let (effects, ..) = authority
            .try_execute_immediately(&cert, ExecutionEnv::new(), &epoch_store)
            .await
            .unwrap();
        assert!(effects.status().is_ok());
        let package_id = effects
            .created()
            .into_iter()
            .find(|(_, owner)| owner.is_immutable())
            .unwrap()
            .0
            .0;
        let gas = effects.gas_object().0;

        let tx = TestTransactionBuilder::new(sender, gas, rgp)
            .move_call(package_id, "object_balance", "new_owned", vec![])
            .build();
        let cert = VerifiedExecutableTransaction::new_for_testing(tx, &keypair);
        let (effects, ..) = authority
            .try_execute_immediately(&cert, ExecutionEnv::new(), &epoch_store)
            .await
            .unwrap();
        assert!(effects.status().is_ok());
        let vault_obj = effects.created().into_iter().next().unwrap().0;
        Self {
            authority,
            epoch_store,
            sender,
            keypair,
            gas_obj: gas.0,
            package_id,
            vault_obj: vault_obj.0,
        }
    }

    pub async fn oref(&self, object_id: &ObjectID) -> ObjectRef {
        self.authority
            .get_object(object_id)
            .await
            .unwrap()
            .compute_object_reference()
    }

    pub fn rgp(&self) -> u64 {
        self.epoch_store.reference_gas_price()
    }

    pub async fn fund_address(&self, address: SuiAddress, amount: u64) {
        let gas = self.oref(&self.gas_obj).await;
        let tx = TestTransactionBuilder::new(self.sender, gas, self.rgp())
            .transfer_sui_to_address_balance(FundSource::coin(gas), vec![(amount, address)])
            .build();
        let cert = VerifiedExecutableTransaction::new_for_testing(tx, &self.keypair);

        let (effects, ..) = self
            .authority
            .try_execute_immediately(&cert, ExecutionEnv::new(), &self.epoch_store)
            .await
            .unwrap();
        assert!(effects.status().is_ok());

        self.authority
            .settle_accumulator_for_testing(&[effects], None)
            .await;
    }

    pub fn get_latest_balance(&self, type_tag: TypeTag) -> u128 {
        let account_id =
            AccumulatorValue::get_field_id(self.vault_obj.into(), &Balance::type_tag(type_tag))
                .unwrap();
        let balance_read = self.authority.get_account_funds_read();
        let (balance, _version) = balance_read.get_latest_account_amount(&account_id);
        balance
    }

    // ---- helpers used by fuzz_cross_boundary_conservation ----

    /// Create an additional owned object-balance vault, returning its id.
    async fn new_vault(&self) -> ObjectID {
        let gas = self.oref(&self.gas_obj).await;
        let tx = TestTransactionBuilder::new(self.sender, gas, self.rgp())
            .move_call(self.package_id, "object_balance", "new_owned", vec![])
            .build();
        let cert = VerifiedExecutableTransaction::new_for_testing(tx, &self.keypair);
        let (effects, ..) = self
            .authority
            .try_execute_immediately(&cert, ExecutionEnv::new(), &self.epoch_store)
            .await
            .unwrap();
        assert!(effects.status().is_ok());
        effects.created().into_iter().next().unwrap().0.0
    }

    /// Read any account's settled balance for a given type, independent of the checker.
    fn balance_of(&self, owner: SuiAddress, type_tag: TypeTag) -> u128 {
        let account_id =
            AccumulatorValue::get_field_id(owner, &Balance::type_tag(type_tag)).unwrap();
        self.authority
            .get_account_funds_read()
            .get_latest_account_amount(&account_id)
            .0
    }

    /// Execute a transaction that touches the accumulator, driving it to completion whether it
    /// takes the fast path or is deferred to consensus (`RetryLater`). Returns the effects and
    /// whether the transaction actually committed its balance changes (status ok).
    async fn exec_any(&self, cert: VerifiedExecutableTransaction) -> (TransactionEffects, bool) {
        let digest = *cert.digest();
        let accumulator_version = self.oref(&SUI_ACCUMULATOR_ROOT_OBJECT_ID).await.1;
        let output = self
            .authority
            .try_execute_immediately(
                &cert,
                ExecutionEnv::new()
                    .with_assigned_versions(AssignedVersions::new(vec![], Some(accumulator_version))),
                &self.epoch_store,
            )
            .await;
        let effects = match output {
            ExecutionOutput::Success(t) => t.0,
            ExecutionOutput::RetryLater => {
                self.authority
                    .notify_read_effects_for_testing("fuzz", digest)
                    .await
            }
            ExecutionOutput::EpochEnded => panic!("unexpected EpochEnded during fuzz execution"),
            ExecutionOutput::Fatal(e) => panic!("fatal execution error during fuzz: {e:?}"),
        };
        let committed = effects.status().is_ok();
        (effects, committed)
    }
}

#[tokio::test]
async fn test_object_withdraw_basic_flow() {
    let env = TestEnv::new().await;

    env.fund_address(env.vault_obj.into(), 1000).await;

    let gas = env.oref(&env.gas_obj).await;
    let tx = TestTransactionBuilder::new(env.sender, gas, env.rgp())
        .transfer_sui_to_address_balance(
            FundSource::object_fund_owned(env.package_id, env.oref(&env.vault_obj).await),
            vec![(1000, env.sender)],
        )
        .build();
    let cert = VerifiedExecutableTransaction::new_for_testing(tx, &env.keypair);

    let accumulator_version = env.oref(&SUI_ACCUMULATOR_ROOT_OBJECT_ID).await.1;
    let effects = env
        .authority
        .try_execute_immediately(
            &cert,
            ExecutionEnv::new()
                .with_assigned_versions(AssignedVersions::new(vec![], Some(accumulator_version))),
            &env.epoch_store,
        )
        .await
        .unwrap()
        .0;
    assert!(effects.status().is_ok());
}

#[tokio::test]
async fn test_object_withdraw_fast_path_abort() {
    let env = TestEnv::new().await;

    env.fund_address(env.vault_obj.into(), 1000).await;

    let gas = env.oref(&env.gas_obj).await;
    let tx = TestTransactionBuilder::new(env.sender, gas, env.rgp())
        .transfer_sui_to_address_balance(
            FundSource::object_fund_owned(env.package_id, env.oref(&env.vault_obj).await),
            vec![(1000, env.sender)],
        )
        .build();
    let cert = VerifiedExecutableTransaction::new_for_testing(tx, &env.keypair);

    let output = env
        .authority
        // Fastpath execution
        .try_execute_immediately(&cert, ExecutionEnv::new(), &env.epoch_store)
        .await;
    assert!(matches!(output, ExecutionOutput::RetryLater));
}

#[tokio::test]
async fn test_object_withdraw_multiple_withdraws() {
    let env = TestEnv::new().await;

    env.fund_address(env.vault_obj.into(), 1000).await;

    let mut all_effects = Vec::new();
    // Withdraw from the same object account 3 times, each 300.
    // All withdraws should be sufficient.
    for _ in 0..3 {
        let gas = env.oref(&env.gas_obj).await;
        let tx = TestTransactionBuilder::new(env.sender, gas, env.rgp())
            .transfer_sui_to_address_balance(
                FundSource::object_fund_owned(env.package_id, env.oref(&env.vault_obj).await),
                vec![(300, env.sender)],
            )
            .build();
        let cert = VerifiedExecutableTransaction::new_for_testing(tx, &env.keypair);

        let accumulator_version = env.oref(&SUI_ACCUMULATOR_ROOT_OBJECT_ID).await.1;
        let effects = env
            .authority
            // Fastpath execution
            .try_execute_immediately(
                &cert,
                ExecutionEnv::new().with_assigned_versions(AssignedVersions::new(
                    vec![],
                    Some(accumulator_version),
                )),
                &env.epoch_store,
            )
            .await
            .unwrap()
            .0;
        assert!(effects.status().is_ok());
        all_effects.push(effects);
    }
    env.authority
        .settle_accumulator_for_testing(&all_effects, None)
        .await;

    assert_eq!(env.get_latest_balance(GAS::type_tag()), 1000 - 300 * 3);

    all_effects.clear();

    // Withdraw from the same object account 3 times, each 40.
    // The first 2 withdraws should be sufficient, the last one should be insufficient.
    // This test exercises the case where we have to track unsettled balance withdraws from the same consensus commit.
    for i in 0..3 {
        let gas = env.oref(&env.gas_obj).await;
        let tx = TestTransactionBuilder::new(env.sender, gas, env.rgp())
            .transfer_sui_to_address_balance(
                FundSource::object_fund_owned(env.package_id, env.oref(&env.vault_obj).await),
                vec![(40, env.sender)],
            )
            .build();
        let cert = VerifiedExecutableTransaction::new_for_testing(tx, &env.keypair);
        let digest = *cert.digest();

        let accumulator_version = env.oref(&SUI_ACCUMULATOR_ROOT_OBJECT_ID).await.1;
        let output = env
            .authority
            // Fastpath execution
            .try_execute_immediately(
                &cert,
                ExecutionEnv::new().with_assigned_versions(AssignedVersions::new(
                    vec![],
                    Some(accumulator_version),
                )),
                &env.epoch_store,
            )
            .await;
        let effects = if i < 2 {
            let effects = output.unwrap().0;
            assert!(effects.status().is_ok());
            effects
        } else {
            assert!(matches!(output, ExecutionOutput::RetryLater));
            let effects = env
                .authority
                .notify_read_effects_for_testing("test", digest)
                .await;
            assert!(matches!(
                effects.status(),
                ExecutionStatus::Failure(ExecutionFailure {
                    error: ExecutionErrorKind::InsufficientFundsForWithdraw,
                    ..
                })
            ));
            effects
        };
        all_effects.push(effects);
    }
    env.authority
        .settle_accumulator_for_testing(&all_effects, None)
        .await;

    assert_eq!(
        env.get_latest_balance(GAS::type_tag()),
        1000 - 300 * 3 - 40 * 2
    );
}

#[tokio::test]
async fn test_object_withdraw_and_deposit_same_transaction() {
    telemetry_subscribers::init_for_testing();
    let env = TestEnv::new().await;
    env.fund_address(env.vault_obj.into(), 2).await;

    // In the same transaction, we are withdrawing from the object account
    // and depositing back to the same object account.
    // The max net withdraws for this account should be 3, because at any given moment,
    // the net withdraws is at most 3.
    // Since the account has a balance of 2, the transaction should fail.
    let gas = env.oref(&env.gas_obj).await;
    let tx = TestTransactionBuilder::new(env.sender, gas, env.rgp())
        .transfer_sui_to_address_balance(
            FundSource::object_fund_owned(env.package_id, env.oref(&env.vault_obj).await),
            vec![(3, env.vault_obj.into())],
        )
        .build();
    let cert = VerifiedExecutableTransaction::new_for_testing(tx, &env.keypair);
    let digest = *cert.digest();
    let accumulator_version = env.oref(&SUI_ACCUMULATOR_ROOT_OBJECT_ID).await.1;
    let output = env
        .authority
        .try_execute_immediately(
            &cert,
            ExecutionEnv::new()
                .with_assigned_versions(AssignedVersions::new(vec![], Some(accumulator_version))),
            &env.epoch_store,
        )
        .await;
    assert!(matches!(output, ExecutionOutput::RetryLater));
    let effects = env
        .authority
        .notify_read_effects_for_testing("test", digest)
        .await;
    assert!(matches!(
        effects.status(),
        ExecutionStatus::Failure(ExecutionFailure {
            error: ExecutionErrorKind::InsufficientFundsForWithdraw,
            ..
        })
    ));

    let gas = env.oref(&env.gas_obj).await;
    // Now we try with withdraw 2 and deposit 2, which should be sufficient,
    // even if we do it twice.
    let tx = TestTransactionBuilder::new(env.sender, gas, env.rgp())
        .transfer_sui_to_address_balance(
            FundSource::object_fund_owned(env.package_id, env.oref(&env.vault_obj).await),
            vec![(2, env.vault_obj.into())],
        )
        .transfer_sui_to_address_balance(
            FundSource::object_fund_owned(env.package_id, env.oref(&env.vault_obj).await),
            vec![(2, env.vault_obj.into())],
        )
        .build();
    let cert = VerifiedExecutableTransaction::new_for_testing(tx, &env.keypair);
    let effects = env
        .authority
        .try_execute_immediately(
            &cert,
            ExecutionEnv::new()
                .with_assigned_versions(AssignedVersions::new(vec![], Some(accumulator_version))),
            &env.epoch_store,
        )
        .await
        .unwrap()
        .0;
    assert!(effects.status().is_ok());

    // Now try to withdraw 1 and deposit 1. Since the previous
    // transaction has a pending withdraw of 2, there is no more balance available.
    // This should fail.
    let gas = env.oref(&env.gas_obj).await;
    let tx = TestTransactionBuilder::new(env.sender, gas, env.rgp())
        .transfer_sui_to_address_balance(
            FundSource::object_fund_owned(env.package_id, env.oref(&env.vault_obj).await),
            vec![(1, env.vault_obj.into())],
        )
        .build();
    let cert = VerifiedExecutableTransaction::new_for_testing(tx, &env.keypair);
    let digest = *cert.digest();
    let output = env
        .authority
        .try_execute_immediately(
            &cert,
            ExecutionEnv::new()
                .with_assigned_versions(AssignedVersions::new(vec![], Some(accumulator_version))),
            &env.epoch_store,
        )
        .await;
    assert!(matches!(output, ExecutionOutput::RetryLater));
    let effects = env
        .authority
        .notify_read_effects_for_testing("test", digest)
        .await;
    assert!(matches!(
        effects.status(),
        ExecutionStatus::Failure(ExecutionFailure {
            error: ExecutionErrorKind::InsufficientFundsForWithdraw,
            ..
        })
    ));
}

// ============================================================================
// Cross-boundary accumulator conservation fuzzer.
//
// Independent oracle: we maintain our own model of every account's settled
// balance, derived only from the balance *deltas of transactions that actually
// committed*. After each batch is settled, the on-chain settled store MUST
// equal our model for every account, and the global sum must equal everything
// ever minted. Any divergence means value was created or destroyed across the
// object-fund / address-fund / deposit boundaries = a conservation break.
//
// The harness is outcome-driven: it never predicts whether the checker will
// accept a withdraw. It executes, observes the real result, and only applies a
// balance delta to the model when the transaction committed. That keeps a
// mispredicted accept/reject from masquerading as a conservation finding.
//
//   cargo nextest run -p sui-core fuzz_cross_boundary_conservation \
//     --run-ignored all --no-capture
// ============================================================================
#[tokio::test]
#[ignore = "cross-boundary accumulator conservation fuzzer (long, deterministic)"]
async fn fuzz_cross_boundary_conservation() {
    use rand::{Rng, SeedableRng, rngs::StdRng};
    use std::collections::BTreeMap;

    const BASE_SEED: u64 = 0xF00D_5417_C0FF_EE01;
    const SEQUENCES: usize = 48;
    const TOPUP: u64 = 100_000;
    const MAXTX: u64 = 8_000;

    telemetry_subscribers::init_for_testing();
    let env = TestEnv::new().await;
    let ty = GAS::type_tag();

    // Three owned object vaults + the sender's address account.
    let vault_ids = vec![env.vault_obj, env.new_vault().await, env.new_vault().await];
    let vault_addrs: Vec<SuiAddress> = vault_ids.iter().copied().map(SuiAddress::from).collect();
    let mut accounts = vec![env.sender];
    accounts.extend(vault_addrs.iter().copied());

    // Map an account address back to its owning vault object id (for object funds).
    let vault_of = |addr: SuiAddress| -> Option<ObjectID> {
        vault_addrs.iter().position(|a| *a == addr).map(|i| vault_ids[i])
    };

    // Independent ledger. `minted` = total ever funded in; `settled` = our model of each
    // account's settled balance (signed so an over-withdraw shows as a negative model value
    // rather than wrapping).
    let mut minted: BTreeMap<SuiAddress, u128> = BTreeMap::new();
    let mut settled: BTreeMap<SuiAddress, i128> = BTreeMap::new();

    // Seed every account and verify the store agrees with our model.
    for a in &accounts {
        env.fund_address(*a, TOPUP).await;
        *minted.entry(*a).or_default() += TOPUP as u128;
        *settled.entry(*a).or_default() += TOPUP as i128;
        assert_eq!(
            env.balance_of(*a, ty.clone()) as i128,
            settled[a],
            "seed store mismatch for {a}"
        );
    }

    for si in 0..SEQUENCES {
        let seed = BASE_SEED ^ (si as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15);
        let mut rng = StdRng::seed_from_u64(seed);

        // Top up every account before the batch (settles immediately).
        for a in &accounts {
            env.fund_address(*a, TOPUP).await;
            *minted.get_mut(a).unwrap() += TOPUP as u128;
            *settled.get_mut(a).unwrap() += TOPUP as i128;
        }

        // Conservative per-account availability, only to choose plausible amounts. Correctness
        // does not depend on it: it merely biases the fuzzer toward transactions that commit.
        let mut avail: BTreeMap<SuiAddress, u128> =
            accounts.iter().map(|a| (*a, settled[a].max(0) as u128)).collect();

        // Settled deltas to apply to the model AFTER settlement, for committed txns only.
        let mut pending: BTreeMap<SuiAddress, i128> = BTreeMap::new();
        let mut effects = Vec::new();
        let mut log: Vec<String> = Vec::new();

        let ntx = rng.gen_range(3..=8);
        for _ in 0..ntx {
            // Pick an object-vault source with something to spend. (Address-fund withdrawals
            // are validated at signing / consensus scheduling, a path this fast-path harness
            // bypasses, so restrict sources to object vaults whose limits are enforced here.)
            let src = vault_addrs[rng.gen_range(0..vault_addrs.len())];
            let src_avail = *avail.get(&src).unwrap_or(&0);
            if src_avail == 0 {
                continue;
            }

            // A non-source account to receive funds (so a deposit back to `src` never
            // masks an over-withdraw when we are trying to force a failure).
            let other = *accounts.iter().find(|a| **a != src).unwrap();

            // 20% of the time deliberately over-withdraw the whole balance plus a bit,
            // sending only to `other` so the net withdrawal strictly exceeds `src_avail`.
            let force_fail = rng.gen_ratio(1, 5);
            let outs: Vec<(u64, SuiAddress)> = if force_fail {
                let total = u64::try_from(src_avail)
                    .unwrap_or(u64::MAX)
                    .saturating_add(rng.gen_range(1..=64));
                vec![(total, other)]
            } else {
                let cap = u64::try_from(src_avail.min(MAXTX as u128)).unwrap();
                let total = rng.gen_range(1..=cap);
                // Split `total` across 1..=3 destination accounts (may deposit back to src).
                let n = rng.gen_range(1..=3);
                let mut rem = total;
                let mut v = Vec::new();
                for i in 0..n {
                    let a = if i + 1 == n { rem } else { rng.gen_range(0..=rem) };
                    rem -= a;
                    v.push((a, accounts[rng.gen_range(0..accounts.len())]));
                }
                v
            };
            let total: u64 = outs.iter().map(|(a, _)| *a).sum();

            let gas = env.oref(&env.gas_obj).await;
            let fund_source = match vault_of(src) {
                Some(vault_id) => {
                    FundSource::object_fund_owned(env.package_id, env.oref(&vault_id).await)
                }
                None => FundSource::address_fund_with_reservation(total),
            };
            let tx = TestTransactionBuilder::new(env.sender, gas, env.rgp())
                .transfer_sui_to_address_balance(fund_source, outs.clone())
                .build();
            let cert = VerifiedExecutableTransaction::new_for_testing(tx, &env.keypair);

            let kind = if vault_of(src).is_some() { "obj" } else { "addr" };
            let (eff, committed) = env.exec_any(cert).await;
            log.push(format!(
                "[{kind}] src={src} total={total} force_fail={force_fail} committed={committed} outs={outs:?}"
            ));
            effects.push(eff);

            if committed {
                // Decrement the soft availability cap by the *net* reduction of `src`
                // (gross withdrawal minus anything deposited straight back to `src`).
                let back_to_src: u128 =
                    outs.iter().filter(|(_, d)| *d == src).map(|(a, _)| *a as u128).sum();
                let net_src = (total as u128).saturating_sub(back_to_src);
                let slot = avail.entry(src).or_default();
                *slot = slot.saturating_sub(net_src);

                *pending.entry(src).or_default() -= total as i128;
                for (a, dst) in &outs {
                    *pending.entry(*dst).or_default() += *a as i128;
                }
            }
        }

        // Settle the whole batch, then apply model deltas for the committed txns.
        env.authority
            .settle_accumulator_for_testing(&effects, None)
            .await;
        for (a, d) in &pending {
            *settled.entry(*a).or_default() += *d;
        }

        // ---- Independent conservation checks ----
        // (1) Authoritative: the total accumulator value actually on chain across every tracked
        // account must equal everything ever minted into them. Gas is paid from a separate coin,
        // so no value legitimately leaves this set. A mismatch = value created or destroyed.
        let actual_total: u128 = accounts.iter().map(|a| env.balance_of(*a, ty.clone())).sum();
        let sum_minted: u128 = minted.values().sum();
        assert_eq!(
            actual_total, sum_minted,
            "\nVALUE CONSERVATION BREAK seed={seed:#x} si={si}\n\
             on_chain_total={actual_total} minted_total={sum_minted} \
             delta={}\n{log:#?}\n",
            actual_total as i128 - sum_minted as i128
        );
        // (2) Per-account: the on-chain balance must match our independent model of committed
        // deltas. Divergence points at which account's accounting is wrong.
        for a in &accounts {
            let modeled = settled.get(a).copied().unwrap_or_default();
            let actual = env.balance_of(*a, ty.clone()) as i128;
            if actual != modeled {
                panic!(
                    "\nCONSERVATION CANDIDATE (per-account)\nseed={seed:#x} si={si}\n\
                     account={a}\nmodeled={modeled} actual={actual} delta={}\noperations:\n{log:#?}\n",
                    actual - modeled
                );
            }
        }
    }

    eprintln!("fuzz_cross_boundary_conservation: {SEQUENCES} sequences, no conservation break");
}
