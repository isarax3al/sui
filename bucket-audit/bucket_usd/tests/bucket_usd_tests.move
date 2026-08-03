#[test_only]
module bucket_v2_usd::bucket_v2_usd_tests;

use std::type_name::{get};
use sui::coin::{Self, Coin};
use sui::balance;
use sui::sui::{SUI};
use sui::test_scenario::{Self as ts, Scenario};
use bucket_v2_framework::account;
use bucket_v2_usd::usdb::{Self, USDB, Treasury};
use bucket_v2_usd::admin::{Self, AdminCap};
use bucket_v2_usd::limited_supply;

public struct CDP has drop {}
public struct PSM has drop {}

public fun admin(): address { @0xde1 }
public fun beneficiary(): address { @0xbfc }
public fun usdb(amount: u64): u64 { amount * 10u64.pow(usdb::decimal()) }
public fun fee(amount: u64): u64 { amount * 5 / 1_000 }

public fun setup<Module: drop>(version: u16, limit: u64): Scenario {
    let module_type = get<Module>();
    let mut scenario = ts::begin(admin());
    let s = &mut scenario;
    admin::init_for_testing(s.ctx());
    usdb::init_for_testing(s.ctx());

    s.next_tx(admin());
    let cap = s.take_from_sender<AdminCap>();
    let mut treasury = s.take_shared<Treasury>();
    treasury.add_version<Module>(&cap, version);
    treasury.set_supply_limit<Module>(&cap, limit);
    treasury.set_beneficiary_address(&cap, beneficiary());
    assert!(treasury.beneficiary_address() == beneficiary());
    assert!(treasury.total_supply() == 0);
    let module_config = treasury.module_config_map().get(&module_type);
    let supply = module_config.limited_supply();
    assert!(supply.limit() == limit);
    assert!(supply.supply() == 0);
    assert!(module_config.valid_versions().contains(&version));
    s.return_to_sender(cap);
    ts::return_shared(treasury);

    scenario
}

#[test]
fun test_bucket_v2_usd() {
    let cdp_version = 1;
    let cdp_limit = usdb(1_000);
    let mut scenario = setup<CDP>(cdp_version, cdp_limit);
    let s = &mut scenario;

    let user_1 = @0x111;
    let mint_amount_1 = usdb(10);
    s.next_tx(user_1);
    let mut treasury = s.take_shared<Treasury>();
    let out = treasury.mint(CDP {}, cdp_version, mint_amount_1, s.ctx());
    treasury.mint(CDP {}, cdp_version, 0, s.ctx()).destroy_zero();
    let fee = coin::mint_for_testing<USDB>(fee(mint_amount_1), s.ctx());
    let fee_amount_1 = fee.value();
    treasury.collect(CDP {}, b"mint_fee".to_string(), fee.into_balance());
    assert!(out.value() == mint_amount_1);
    assert!(treasury.total_supply() == mint_amount_1);
    let cdp_module_type = get<CDP>();
    assert!(treasury.claimable_map<USDB>().get(&cdp_module_type).value() == fee_amount_1);
    let supply = treasury.module_config_map().get(&cdp_module_type).limited_supply();
    assert!(supply.limit() == cdp_limit);
    assert!(supply.supply() == mint_amount_1);
    transfer::public_transfer(out, user_1);
    ts::return_shared(treasury);

    s.next_tx(beneficiary());
    let mut treasury = s.take_shared<Treasury>();
    let request = account::request(s.ctx());
    treasury.claim<SUI, CDP>(&request, s.ctx()).destroy_none();
    treasury.claim<USDB, PSM>(&request, s.ctx()).destroy_none();
    ts::return_shared(treasury);

    let user_2 = @0x222;
    let mint_amount_2 = usdb(69);
    s.next_tx(user_2);
    let mut treasury = s.take_shared<Treasury>();
    let out = treasury.mint(CDP {}, cdp_version,mint_amount_2, s.ctx());
    let fee = coin::mint_for_testing<USDB>(fee(mint_amount_2), s.ctx());
    let fee_amount_2 = fee.value();
    treasury.collect(CDP {}, b"mint_fee".to_string(), fee.into_balance());
    assert!(out.value() == mint_amount_2);
    assert!(treasury.total_supply() == mint_amount_1 + mint_amount_2);
    assert!(treasury.claimable_map<USDB>().get(&cdp_module_type).value() == fee_amount_1 + fee_amount_2);
    let supply = treasury.module_config_map().get(&cdp_module_type).limited_supply();
    assert!(supply.limit() == cdp_limit);
    assert!(supply.supply() == mint_amount_1 + mint_amount_2);
    transfer::public_transfer(out, user_2);
    ts::return_shared(treasury);

    s.next_tx(user_2);
    let burn_amount_2 = usdb(9);
    let mut treasury = s.take_shared<Treasury>();
    let mut usdb_coin = s.take_from_sender<Coin<USDB>>();
    let coin_to_burn = usdb_coin.split(burn_amount_2, s.ctx());
    treasury.burn(CDP {}, cdp_version, coin_to_burn);
    treasury.burn(CDP {}, cdp_version, coin::zero(s.ctx()));
    assert!(treasury.total_supply() == mint_amount_1 + mint_amount_2 - burn_amount_2);
    let supply = treasury.module_config_map().get(&cdp_module_type).limited_supply();
    assert!(supply.limit() == cdp_limit);
    assert!(supply.supply() == mint_amount_1 + mint_amount_2 - burn_amount_2);
    ts::return_shared(treasury);
    s.return_to_sender(usdb_coin);

    let psm_version = 2;
    let psm_version_ext = 3;
    let psm_limit = usdb(50);
    s.next_tx(admin());
    let cap = s.take_from_sender<AdminCap>();
    let mut treasury = s.take_shared<Treasury>();
    treasury.add_version<PSM>(&cap, psm_version);
    treasury.add_version<PSM>(&cap, psm_version_ext);
    treasury.set_supply_limit<PSM>(&cap, psm_limit);
    s.return_to_sender(cap);
    ts::return_shared(treasury);

    let user_3 = @0x333;
    let mint_amount_3 = usdb(50);
    s.next_tx(user_3);
    let mut treasury = s.take_shared<Treasury>();
    let psm_module_type = get<PSM>();
    let out = treasury.mint(PSM {}, psm_version, mint_amount_3, s.ctx());
    let fee = coin::mint_for_testing<USDB>(fee(mint_amount_3), s.ctx());
    let fee_amount_3 = fee.value();
    treasury.collect(PSM {}, b"in_fee".to_string(), fee.into_balance());
    assert!(out.value() == mint_amount_3);
    assert!(treasury.total_supply() == mint_amount_1 + mint_amount_2 - burn_amount_2 + mint_amount_3);
    assert!(treasury.claimable_map<USDB>().get(&psm_module_type).value() == fee_amount_3);
    let supply = treasury.module_config_map().get(&psm_module_type).limited_supply();
    assert!(supply.limit() == psm_limit);
    assert!(supply.supply() == mint_amount_3);
    transfer::public_transfer(out, user_3);
    ts::return_shared(treasury);

    s.next_tx(user_3);
    let burn_amount_3 = usdb(15);
    let mut treasury = s.take_shared<Treasury>();
    let mut usdb_coin = s.take_from_sender<Coin<USDB>>();
    let coin_to_burn = usdb_coin.split(burn_amount_3, s.ctx());
    treasury.burn(PSM {}, psm_version_ext, coin_to_burn);
    assert!(treasury.total_supply() == mint_amount_1 + mint_amount_2 - burn_amount_2 + mint_amount_3 - burn_amount_3);
    let supply = treasury.module_config_map().get(&psm_module_type).limited_supply();
    assert!(supply.limit() == psm_limit);
    assert!(supply.supply() == mint_amount_3 - burn_amount_3);
    let fee_amount_3s = 1_320_000_000;
    let fee = coin::mint_for_testing<SUI>(fee_amount_3s, s.ctx());
    treasury.collect(PSM {}, b"farming".to_string(), fee.into_balance());
    assert!(treasury.claimable_map<SUI>().get(&psm_module_type).value() == fee_amount_3s);
    ts::return_shared(treasury);
    s.return_to_sender(usdb_coin);

    s.next_tx(beneficiary());
    let mut treasury = s.take_shared<Treasury>();
    let request = account::request(s.ctx());
    let usdb_out = treasury.claim<USDB, CDP>(&request, s.ctx()).destroy_some();
    assert!(usdb_out.value() == fee_amount_1 + fee_amount_2);
    transfer::public_transfer(usdb_out, beneficiary());
    let usdb_out = treasury.claim<USDB, PSM>(&request, s.ctx()).destroy_some();
    assert!(usdb_out.value() == fee_amount_3);
    transfer::public_transfer(usdb_out, beneficiary());
    treasury.claim<SUI, CDP>(&request, s.ctx()).destroy_none();
    let sui_out = treasury.claim<SUI, PSM>(&request, s.ctx()).destroy_some();
    assert!(sui_out.value() == fee_amount_3s);
    transfer::public_transfer(sui_out, beneficiary());
    ts::return_shared(treasury);

    scenario.end();
}

#[test, expected_failure(abort_code = usdb::ENotBeneficiary)]
fun test_not_beneficiary() {
    let cdp_version = 1;
    let cdp_limit = usdb(1_000);
    let mut scenario = setup<CDP>(cdp_version, cdp_limit);
    let s = &mut scenario;

    s.next_tx(@0x123);
    let mut treasury = s.take_shared<Treasury>();
    let fee_amount = usdb(3);
    let fee = coin::mint_for_testing<USDB>(fee_amount, s.ctx());
    treasury.collect(CDP {}, b"mint_fee".to_string(), fee.into_balance());
    ts::return_shared(treasury);

    s.next_tx(@0x123);
    let mut treasury = s.take_shared<Treasury>();
    let request = account::request(s.ctx());
    treasury.claim<USDB, CDP>(&request, s.ctx()).destroy_some().burn_for_testing();
    ts::return_shared(treasury);

    scenario.end();
}

#[test, expected_failure(abort_code = usdb::ECoinTypeNotFound)]
fun test_coin_type_not_found() {
    let cdp_version = 1;
    let cdp_limit = usdb(1_000);
    let mut scenario = setup<CDP>(cdp_version, cdp_limit);
    let s = &mut scenario;

    s.next_tx(@0x123);
    let mut treasury = s.take_shared<Treasury>();
    treasury.collect(PSM {}, b"farming".to_string(), balance::zero<USDB>());
    let usdb_map = treasury.claimable_map<USDB>();
    assert!(usdb_map.is_empty());
    ts::return_shared(treasury);

    scenario.end();
}

#[test, expected_failure(abort_code = limited_supply::ESupplyExceedLimit)]
fun test_supply_exceed_limit() {
    let cdp_version = 1;
    let cdp_limit = usdb(200);
    let mut scenario = setup<CDP>(cdp_version, cdp_limit);
    let s = &mut scenario;

    s.next_tx(admin());
    let cap = s.take_from_sender<AdminCap>();
    let mut treasury = s.take_shared<Treasury>();
    treasury.set_supply_limit<CDP>(&cap, usdb(100));
    s.return_to_sender(cap);
    ts::return_shared(treasury);

    let user_1 = @0x111;
    let mint_amount_1 = usdb(101);
    s.next_tx(user_1);
    let mut treasury = s.take_shared<Treasury>();
    let out = treasury.mint(CDP {}, 1, mint_amount_1, s.ctx());
    treasury.mint(CDP {}, 1, 0, s.ctx()).destroy_zero();
    transfer::public_transfer(out, user_1);
    ts::return_shared(treasury);

    scenario.end();
}

#[test, expected_failure(abort_code = usdb::EInvalidModule)]
fun test_invald_module() {
    let cdp_version = 1;
    let cdp_limit = usdb(200);
    let mut scenario = setup<CDP>(cdp_version, cdp_limit);
    let s = &mut scenario;

    s.next_tx(admin());
    let cap = s.take_from_sender<AdminCap>();
    let mut treasury = s.take_shared<Treasury>();
    treasury.remove_module<CDP>(&cap);
    s.return_to_sender(cap);
    ts::return_shared(treasury);

    let user_1 = @0x111;
    let mint_amount_1 = usdb(101);
    s.next_tx(user_1);
    let mut treasury = s.take_shared<Treasury>();
    let out = treasury.mint(CDP {}, 1, mint_amount_1, s.ctx());
    treasury.mint(CDP {}, 1, 0, s.ctx()).destroy_zero();
    transfer::public_transfer(out, user_1);
    ts::return_shared(treasury);

    scenario.end();
}

#[test, expected_failure(abort_code = usdb::EInvalidModuleVersion)]
fun test_invald_module_version() {
    let cdp_version = 1;
    let cdp_limit = usdb(200);
    let mut scenario = setup<CDP>(cdp_version, cdp_limit);
    let s = &mut scenario;

    s.next_tx(admin());
    let cap = s.take_from_sender<AdminCap>();
    let mut treasury = s.take_shared<Treasury>();
    treasury.remove_version<PSM>(&cap, cdp_version);
    treasury.remove_version<CDP>(&cap, cdp_version + 1);
    treasury.remove_version<CDP>(&cap, cdp_version);
    s.return_to_sender(cap);
    ts::return_shared(treasury);

    let user_1 = @0x111;
    let mint_amount_1 = usdb(101);
    s.next_tx(user_1);
    let mut treasury = s.take_shared<Treasury>();
    let out = treasury.mint(CDP {}, 1, mint_amount_1, s.ctx());
    treasury.mint(CDP {}, 1, 0, s.ctx()).destroy_zero();
    transfer::public_transfer(out, user_1);
    ts::return_shared(treasury);

    scenario.end();
}

#[test, expected_failure(abort_code = limited_supply::EDestroyNonEmptySupply)]
fun test_destroy_non_empty_supply() {
    let cdp_version = 1;
    let cdp_limit = usdb(200);
    let mut scenario = setup<CDP>(cdp_version, cdp_limit);
    let s = &mut scenario;

    let user_1 = @0x111;
    let mint_amount_1 = usdb(101);
    s.next_tx(user_1);
    let mut treasury = s.take_shared<Treasury>();
    let out = treasury.mint(CDP {}, cdp_version, mint_amount_1, s.ctx());
    transfer::public_transfer(out, user_1);
    ts::return_shared(treasury);

    s.next_tx(admin());
    let cap = s.take_from_sender<AdminCap>();
    let mut treasury = s.take_shared<Treasury>();
    treasury.remove_module<CDP>(&cap);
    s.return_to_sender(cap);
    ts::return_shared(treasury);

    scenario.end();
}
