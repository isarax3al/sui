#[test_only]
module bucket_v2_cdp::bucket_v2_cdp_tests;

use std::type_name::{get};
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};
use sui::sui::{SUI};
use sui::coin;
use bucket_v2_framework::float::{Self, Float};
use bucket_v2_framework::double::{Self, Double};
use bucket_v2_framework::{account};
use bucket_v2_oracle::{result as price_result};
use bucket_v2_usd::bucket_v2_usd_tests::{Self, admin};
use bucket_v2_usd::admin::{AdminCap};
use bucket_v2_usd::usdb::{Self, USDB, Treasury};
use bucket_v2_cdp::witness::{BucketV2CDP};
use bucket_v2_cdp::vault::{Self, Vault};
use bucket_v2_cdp::acl;

public fun start_timestamp(): u64 { 1745301421843 }
public fun min_collateral_ratio(): Float { float::from_percent(110) }
public fun interest_rate(): Double { double::from_bps(5_50) }
public fun sui(amount: u64): u64 { amount * 1_000_000_000 }
public fun usdb(amount: u64): u64 { amount * 10u64.pow(usdb::decimal()) }
public fun one_year(): u64 { 31_536_000_000 }

public struct RequestCheck has drop {}
public struct ResponseCheck has drop {}

public fun setup<T, LR: drop>(decimal: u8, supply_limit: u64): Scenario {
    let mut scenario = bucket_v2_usd_tests::setup<BucketV2CDP>(1, supply_limit);
    let s = &mut scenario;

    s.next_tx(admin());
    let cap = s.take_from_sender<AdminCap>();
    let treasury = s.take_shared<Treasury>();
    let mut clock = clock::create_for_testing(s.ctx());
    clock.set_for_testing(start_timestamp());
    let mut vault = vault::new<T, LR>(
        &treasury,
        &cap,
        decimal,
        interest_rate(),
        supply_limit,
        min_collateral_ratio(),
        s.ctx(),
    );
    vault.add_request_check<T, RequestCheck>(&cap);
    vault.add_response_check<T, ResponseCheck>(&cap);
    transfer::public_share_object(vault);
    clock.share_for_testing();
    s.return_to_sender(cap);
    ts::return_shared(treasury);

    scenario
}

public fun time_pass(s: &mut Scenario, tick: u64) {
    s.next_tx(@0x0);
    let mut clock = s.take_shared<Clock>();
    clock.increment_for_testing(tick);
    ts::return_shared(clock);
}

public fun manage_position<T>(
    s: &mut Scenario,
    user: address,
    deposit_amount: u64,
    borrow_amount: u64,
    repay_amount: u64,
    withdraw_amount: u64,
    current_price_bps: Option<u64>
): (u64, u64) {
    s.next_tx(user);
    let clock = s.take_shared<Clock>();
    let mut vault = s.take_shared<Vault<T>>();
    let mut treasury = s.take_shared<Treasury>();
    let position_exits = vault.position_exists(user);
    let (coll_amount_before, debt_amount_before) = if (position_exits) {
        let (coll_amount, debt_amount, _) = vault.get_raw_position_data(user);
        (coll_amount, debt_amount)
    } else {
        (0, 0)
    };
    let acc_req = account::request(s.ctx());
    let deposit = coin::mint_for_testing<T>(deposit_amount, s.ctx());
    let repayment = coin::mint_for_testing<USDB>(repay_amount, s.ctx());
    let mut update_req = vault.debtor_request(
        &acc_req,
        &treasury,
        deposit,
        borrow_amount,
        repayment,
        withdraw_amount,
    );
    update_req.add_witness(RequestCheck {});
    assert!(update_req.account() == user);
    assert!(update_req.witnesses().contains(&get<RequestCheck>()));
    assert!(!update_req.witnesses().contains(&get<ExtraRequestCheck>()));
    let coll_price_opt = current_price_bps.map!(
        |price| price_result::new_for_testing<T>(float::from_bps(price))
    );
    let (coll_coin, usdb_coin, mut update_res) = vault.update_position(
        &mut treasury,
        &clock,
        &coll_price_opt,
        update_req,
        s.ctx(),
    );
    let position_exits = vault.position_exists(user);
    let (coll_amount_after, debt_amount_after) = if (position_exits) {
        let (coll_amount, debt_amount) = vault.get_position_data(user, &clock);
        (coll_amount, debt_amount)
    } else {
        (0, 0)
    };
    assert!(coll_amount_before + deposit_amount - withdraw_amount == coll_amount_after);
    update_res.add_witness(ResponseCheck {});
    assert!(update_res.witnesses().contains(&get<ResponseCheck>()));
    assert!(!update_res.witnesses().contains(&get<ExtraResponseCheck>()));
    assert!(update_res.account() == user);
    assert!(update_res.coll_amount() == coll_amount_after);
    assert!(update_res.debt_amount() == debt_amount_after);
    assert!(debt_amount_before + borrow_amount + update_res.interest_amount() - repay_amount == debt_amount_after);
    vault.destroy_response(&treasury, update_res);
    assert!(coll_coin.value() == withdraw_amount);
    assert!(usdb_coin.value() == borrow_amount);
    coll_coin.burn_for_testing();
    usdb_coin.burn_for_testing();
    ts::return_shared(clock);
    ts::return_shared(vault);
    ts::return_shared(treasury);
    (coll_amount_after, debt_amount_after)
}

public fun donate<T>(
    s: &mut Scenario,
    beneficiarty: address,
    deposit_amount: u64,
    repay_amount: u64,
): (u64, u64) {
    s.next_tx(@0x0);
    let clock = s.take_shared<Clock>();
    let mut vault = s.take_shared<Vault<T>>();
    let mut treasury = s.take_shared<Treasury>();
    let deposit = coin::mint_for_testing<T>(deposit_amount, s.ctx());
    let repayment = coin::mint_for_testing<USDB>(repay_amount, s.ctx());
    let mut update_req = vault.donor_request(
        &treasury, beneficiarty, deposit, repayment,
    );
    assert!(update_req.account() == beneficiarty);
    assert!(update_req.borrow_amount() == 0);
    assert!(update_req.withdraw_amount() == 0);
    update_req.add_witness(RequestCheck {});
    let (coll_coin, usdb_coin, mut update_res) = vault.update_position(
        &mut treasury, &clock, &option::none(), update_req, s.ctx(),
    );
    coll_coin.destroy_zero();
    usdb_coin.destroy_zero();
    update_res.add_witness(ResponseCheck {});
    assert!(update_res.account() == beneficiarty);
    vault.destroy_response(&treasury, update_res);
    let (coll_amount, debt_amount) = vault.get_position_data(beneficiarty, &clock);
    ts::return_shared(clock);
    ts::return_shared(vault);
    ts::return_shared(treasury);
    (coll_amount, debt_amount)
}

public fun liquidate<T>(
    s: &mut Scenario,
    liquidator: address,
    debtor: address,
    repay_amount: Option<u64>,
    current_price_bps: u64,
): u64 {
    s.next_tx(liquidator);
    let clock = s.take_shared<Clock>();
    let mut vault = s.take_shared<Vault<T>>();
    let mut treasury = s.take_shared<Treasury>();
    let coll_price = price_result::new_for_testing<T>(float::from_bps(current_price_bps));
    let (_, debt_amount) = vault.get_position_data(debtor, &clock);
    let repayment = coin::mint_for_testing(
        repay_amount.destroy_with_default(debt_amount), s.ctx(),
    );
    let mut update_req = vault.liquidate(
        &treasury, &clock, &coll_price, debtor, repayment, LiquidationRule {}, s.ctx()
    );
    assert!(update_req.account() == debtor);
    assert!(update_req.borrow_amount() == 0);
    assert!(update_req.deposit_amount() == 0);
    update_req.add_witness(RequestCheck {});
    let (coll_coin, usdb_coin, mut update_res) = vault.update_position(
        &mut treasury, &clock, &option::some(coll_price), update_req, s.ctx(),
    );
    update_res.add_witness(ResponseCheck {});
    vault.destroy_response(&treasury, update_res);
    assert!(usdb_coin.value() == 0);
    usdb_coin.destroy_zero();
    let out_amount = coll_coin.value();
    coll_coin.burn_for_testing();

    ts::return_shared(clock);
    ts::return_shared(vault);
    ts::return_shared(treasury);
    out_amount
}

public fun check_position<T>(
    s: &mut Scenario,
    user: address,
    position_exists: bool,
    expected_coll_amount: u64,
    expected_debt_amount: u64,
) {
    s.next_tx(@0x0);
    let clock = s.take_shared<Clock>();
    let vault = s.take_shared<Vault<T>>();
    assert!(vault.position_exists(user) == position_exists);
    if (position_exists) {
        let (coll_amount, debt_amount) = vault.get_position_data(user, &clock);
        assert!(coll_amount == expected_coll_amount);
        assert!(debt_amount == expected_debt_amount);
    };
    ts::return_shared(clock);
    ts::return_shared(vault);
}

public struct LiquidationRule has drop {}

#[test]
fun test_overall() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_451);
    let price_bps = 1597;
    let (coll_amount, debt_amount) = manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );
    assert!(coll_amount == deposit_amount);
    assert!(debt_amount == borrow_amount);

    // pass 1 year
    time_pass(s, one_year());

    // check position
    check_position<SUI>(s, user,
        true,
        deposit_amount,
        interest_rate().add_u64(1).mul_u64(borrow_amount).ceil(),
    );

    // donor deposit and repay
    let coll_donation_amount = sui(500);
    let usdb_donation_amount = interest_rate().mul_u64(borrow_amount).ceil();
    let (coll_amount, debt_amount) = donate<SUI>(s, user,
        coll_donation_amount,
        usdb_donation_amount,
    );
    assert!(coll_amount == deposit_amount + coll_donation_amount);
    assert!(debt_amount == borrow_amount);

    // pass half year
    time_pass(s, one_year() / 2);

    // debtor withdraw
    let withdraw_amount = coll_donation_amount / 4;
    let price_bps = 1597;
    let (coll_amount, debt_amount) = manage_position<SUI>(s, user,
        0,
        0,
        0,
        withdraw_amount,
        option::some(price_bps),
    );
    assert!(coll_amount == deposit_amount + coll_donation_amount * 3 / 4);
    assert!(debt_amount == interest_rate().div_u64(2).add_u64(1).mul_u64(borrow_amount).ceil());

    // pass 1 year
    time_pass(s, one_year());

    // set supply limit = 0 and remove checks
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    vault.set_supply_limit(&cap, 0);
    vault.remove_request_check<SUI, RequestCheck>(&cap);
    vault.remove_response_check<SUI, ResponseCheck>(&cap);
    ts::return_shared(vault);
    s.return_to_sender(cap);

    // check position
    check_position<SUI>(s, user,
        true,
        coll_amount,
        interest_rate().add_u64(1).mul_u64(debt_amount).ceil(),
    );

    // liquidate
    let liquidator = @0xcafe;
    let price_bps = 1597;
    let out_amount = liquidate<SUI>(s, liquidator, user,
        option::none(),
        price_bps,
    );
    assert!(out_amount == coll_amount);

    // check position
    check_position<SUI>(s, user, false, 0, 0);

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EOaclePriceIsRequired)]
fun test_borrow_without_oracle_price() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_451);
    manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::none(),
    );

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EOaclePriceIsRequired)]
fun test_withdraw_without_oracle_price() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_451);
    let price_bps = 1597;
    manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );

    manage_position<SUI>(s, user,
        0,
        0,
        10,
        1,
        option::none(),
    );

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EPositionIsNotHealthy)]
fun test_position_is_not_healthy() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_452);
    let price_bps = 1597;
    manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EPositionIsHealthy)]
fun test_position_is_healthy() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_451);
    let price_bps = 1597;
    manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );

    liquidate<SUI>(s, @0x111, user, option::some(borrow_amount), price_bps);

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EInvalidLiquidation)]
fun test_invalid_liquidation() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    vault.set_liquidation_rule<SUI, SUI>(&cap);
    ts::return_shared(vault);
    s.return_to_sender(cap);

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_451);
    let price_bps = 1597;
    manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );

    liquidate<SUI>(s, @0x111, user, option::some(borrow_amount), price_bps);

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EDebtorNotFound)]
fun test_debtor_not_found() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_000);
    let price_bps = 1597;
    manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );

    // 5 days
    time_pass(s, one_year());

    let price_bps = 1160;
    liquidate<SUI>(s, @0x111, user, option::none(), price_bps);

    s.next_tx(user);
    let vault = s.take_shared<Vault<SUI>>();
    let clock = s.take_shared<Clock>();
    vault.get_position_data(user, &clock);
    ts::return_shared(vault);
    ts::return_shared(clock);

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EDebtorNotFound)]
fun test_debtor_not_found_raw() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_000);
    let price_bps = 1597;
    manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );

    // 5 days
    time_pass(s, one_year());

    let price_bps = 1160;
    liquidate<SUI>(s, @0x111, user, option::none(), price_bps);

    s.next_tx(user);
    let vault = s.take_shared<Vault<SUI>>();
    vault.get_raw_position_data(user);
    ts::return_shared(vault);

    scenario.end();
}

#[test, expected_failure(abort_code = vault::ERepayTooMuch)]
fun test_repay_too_much() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_000);
    let price_bps = 1597;
    manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );

    // 5 days
    time_pass(s, one_year());

    manage_position<SUI>(s, user,
        0,
        0,
        borrow_amount * 10550 / 10000 + 1,
        0,
        option::none(),
    );

    s.next_tx(user);
    let vault = s.take_shared<Vault<SUI>>();
    let clock = s.take_shared<Clock>();
    vault.get_position_data(user, &clock);
    ts::return_shared(vault);
    ts::return_shared(clock);

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EWithdrawTooMuch)]
fun test_withdraw_too_much() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_000);
    let price_bps = 1597;
    manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );

    manage_position<SUI>(s, user,
        0,
        0,
        borrow_amount,
        deposit_amount + 1,
        option::none(),
    );

    s.next_tx(user);
    let vault = s.take_shared<Vault<SUI>>();
    let clock = s.take_shared<Clock>();
    vault.get_position_data(user, &clock);
    ts::return_shared(vault);
    ts::return_shared(clock);

    scenario.end();
}

public struct ExtraRequestCheck has drop {}
public struct ExtraResponseCheck has drop {}

#[test, expected_failure(abort_code = vault::EMissingRequestWitness)]
fun test_missing_request_witness() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    vault.add_request_check<SUI, ExtraRequestCheck>(&cap);
    vault.add_request_check<SUI, ExtraRequestCheck>(&cap);
    ts::return_shared(vault);
    s.return_to_sender(cap);

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_000);
    let price_bps = 1597;
    manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EMissingResponseWitness)]
fun test_missing_response_witness() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    vault.add_response_check<SUI, ExtraResponseCheck>(&cap);
    vault.add_response_check<SUI, ExtraResponseCheck>(&cap);
    ts::return_shared(vault);
    s.return_to_sender(cap);

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_000);
    let price_bps = 1597;
    manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );

    scenario.end();
}

#[test]
fun test_position_order() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    let mut users = vector::tabulate!(
        10, |n| sui::address::from_u256((n + 1) as u256)
    );

    let deposit_amount = sui(1_000);
    let borrow_amount = usdb(100);
    let price_bps = 1592;
    users.do!(|user| {
        manage_position<SUI>(s, user,
            deposit_amount,
            borrow_amount,
            0,
            0,
            option::some(price_bps),
        );
        time_pass(s, 3600_000);
    });

    s.next_tx(@0x0);
    let vault = s.take_shared<Vault<SUI>>();
    let clock = s.take_shared<Clock>();
    let (positions, next_cursor) = vault.get_positions(&clock, option::none(), 5);
    // std::debug::print(&positions);
    assert!(positions.length() == 5);
    assert!(next_cursor.borrow() == @0x6);
    let (positions, next_cursor) = vault.get_positions(&clock, option::none(), 10);
    assert!(positions.length() == 10);
    assert!(next_cursor.is_none());
    positions.zip_do!(users, |pos, user| {
       let (debtor, coll_amount, _) = pos.data();
       assert!(debtor == user);
       assert!(coll_amount == deposit_amount);
    });
    ts::return_shared(vault);
    ts::return_shared(clock);

    time_pass(s, 300 * 86400_000);

    users.reverse();
    users.do!(|user| {
        manage_position<SUI>(s, user,
            0,
            0,
            borrow_amount / 2,
            deposit_amount / 2,
            option::some(price_bps),
        );
        time_pass(s, 3600_000);
    });
    users.reverse();

    time_pass(s, 65 * 86400_000 - 3600_000);

    s.next_tx(@0x0);
    let vault = s.take_shared<Vault<SUI>>();
    let clock = s.take_shared<Clock>();
    let (positions, next_cursor) = vault.get_positions(&clock, option::none(), 20);
    // std::debug::print(&positions);
    assert!(positions.length() == 10);
    positions.zip_do!(users, |pos, user| {
       let (debtor, coll_amount, _) = pos.data();
       assert!(debtor == user);
       assert!(coll_amount == deposit_amount / 2);
    });
    assert!(next_cursor.is_none());
    ts::return_shared(vault);
    ts::return_shared(clock);

    let even_users = users.filter!(|user| (*user).to_u256() % 2 == 0);
    even_users.do!(|user| {
        time_pass(s, 3600_000);

        s.next_tx(user);
        let vault = s.take_shared<Vault<SUI>>();
        let clock = s.take_shared<Clock>();
        let (coll_amount, debt_amount) = vault.get_position_data(user, &clock);
        ts::return_shared(vault);
        ts::return_shared(clock);

        manage_position<SUI>(s, user,
            0,
            0,
            debt_amount,
            coll_amount,
            option::none(),
        );
    });

    s.next_tx(@0x0);
    let vault = s.take_shared<Vault<SUI>>();
    let clock = s.take_shared<Clock>();
    let (positions, next_cursor) = vault.get_positions(&clock, option::none(), 10);
    // std::debug::print(&positions);
    assert!(positions.length() == 5);
    let odd_users = users.filter!(|user| (*user).to_u256() % 2 == 1);
    positions.zip_do!(odd_users, |pos, user| {
       let (debtor, coll_amount, _) = pos.data();
       assert!(debtor == user);
       assert!(coll_amount == deposit_amount / 2);
    });
    assert!(next_cursor.is_none());
    ts::return_shared(vault);
    ts::return_shared(clock);

    scenario.end();
}

public struct Redemption has drop {}

#[test, expected_failure(abort_code = vault::EAgainstSecurityLevel)]
fun test_strictest_security_for_deposit_action() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    // set security to 1
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    vault.set_security_by_admin(&cap, option::some(1), s.ctx());
    ts::return_shared(vault);
    s.return_to_sender(cap);

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_451);
    let price_bps = 1597;
    let (coll_amount, debt_amount) = manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );
    assert!(coll_amount == deposit_amount);
    assert!(debt_amount == borrow_amount);

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EAgainstSecurityLevel)]
fun test_strictest_security_for_other_action() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    // deposit
    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(100);
    let price_bps = 1597;
    let (coll_amount, debt_amount) = manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );
    assert!(coll_amount == deposit_amount);
    assert!(debt_amount == borrow_amount);

    // pass 1
    time_pass(s, 86400 * 1000);

    // set security to 1
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    vault.set_security_by_admin(&cap, option::some(1), s.ctx());
    ts::return_shared(vault);
    s.return_to_sender(cap);

    // debtor withdraw
    let withdraw_amount = sui(500);
    let price_bps = 1597;
    manage_position<SUI>(s, user,
        0,
        0,
        0,
        withdraw_amount,
        option::some(price_bps),
    );

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EAgainstSecurityLevel)]
fun test_strictest_security_for_liquidation() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    // deposit
    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_451);
    let price_bps = 1597;
    let (coll_amount, debt_amount) = manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );
    assert!(coll_amount == deposit_amount);
    assert!(debt_amount == borrow_amount);

    // pass 1 year
    time_pass(s, one_year());

    // set security to 1
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    vault.set_security_by_admin(&cap, option::some(1), s.ctx());
    ts::return_shared(vault);
    s.return_to_sender(cap);

    // liquidate
    let liquidator = @0xcafe;
    let price_bps = 1597;
    let out_amount = liquidate<SUI>(s, liquidator, user,
        option::none(),
        price_bps,
    );
    assert!(out_amount == coll_amount);

    scenario.end();
}

#[test]
fun test_minor_security_for_deposit() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    // set security to 2; which deposit action is allowed but still fail with positive borrow value
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    vault.set_security_by_admin(&cap, option::some(2), s.ctx());
    ts::return_shared(vault);
    s.return_to_sender(cap);

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(0);
    let price_bps = 1597;
    let (coll_amount, debt_amount) = manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );
    assert!(coll_amount == deposit_amount);
    assert!(debt_amount == borrow_amount);

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EAgainstSecurityLevel)]
fun test_minor_security_for_deposit_with_positive_borrow() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    // set security to 2; which deposit action is allowed but still fail with positive borrow value
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    vault.set_security_by_admin(&cap, option::some(1), s.ctx());
    ts::return_shared(vault);
    s.return_to_sender(cap);

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_451);
    let price_bps = 1597;
    let (coll_amount, debt_amount) = manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );
    assert!(coll_amount == deposit_amount);
    assert!(debt_amount == borrow_amount);

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EAgainstSecurityLevel)]
fun test_minor_security_for_other_actions() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    // deposit
    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(100);
    let price_bps = 1597;
    let (coll_amount, debt_amount) = manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );
    assert!(coll_amount == deposit_amount);
    assert!(debt_amount == borrow_amount);

    // pass 1
    time_pass(s, 86400 * 1000);

    // set security to 1
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    vault.set_security_by_admin(&cap, option::some(2), s.ctx());
    ts::return_shared(vault);
    s.return_to_sender(cap);

    // debtor withdraw
    let withdraw_amount = sui(500);
    let price_bps = 1597;
    manage_position<SUI>(s, user,
        0,
        0,
        0,
        withdraw_amount,
        option::some(price_bps),
    );

    scenario.end();
}

#[test]
fun test_minor_security_for_available_liquidation() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    // deposit
    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_451);
    let price_bps = 1597;
    let (coll_amount, debt_amount) = manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );
    assert!(coll_amount == deposit_amount);
    assert!(debt_amount == borrow_amount);

    // pass 1 year
    time_pass(s, one_year());

    // set security to 1
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    vault.set_security_by_admin(&cap, option::some(2), s.ctx());
    ts::return_shared(vault);
    s.return_to_sender(cap);

    // liquidate
    let liquidator = @0xcafe;
    let price_bps = 1597;
    let out_amount = liquidate<SUI>(s, liquidator, user,
        option::none(),
        price_bps,
    );
    assert!(out_amount == coll_amount);

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EAgainstSecurityLevel)]
fun test_minor_security_for_liquidation() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    // deposit
    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_451);
    let price_bps = 1597;
    let (coll_amount, debt_amount) = manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );
    assert!(coll_amount == deposit_amount);
    assert!(debt_amount == borrow_amount);

    // pass 1 year
    time_pass(s, one_year());

    // set security to 1
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    vault.set_security_by_admin(&cap, option::some(1), s.ctx());
    ts::return_shared(vault);
    s.return_to_sender(cap);

    // liquidate
    let liquidator = @0xcafe;
    let price_bps = 1597;
    let out_amount = liquidate<SUI>(s, liquidator, user,
        option::none(),
        price_bps,
    );
    assert!(out_amount == coll_amount);

    scenario.end();
}

#[test, expected_failure(abort_code = acl::EInvalidRole)]
fun test_set_manager_role_err_invalid_level() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    // assign manager role
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    let manager = @234;
    vault.set_manager_role(&cap, manager, 0);
    ts::return_shared(vault);
    s.return_to_sender(cap);

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EAgainstSecurityLevel)]
fun test_set_manager_role_with_strictest_level() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    // assign manager role
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    let manager = @234;
    vault.set_manager_role(&cap, manager, 1);
    ts::return_shared(vault);
    s.return_to_sender(cap);
    // toggle security
    s.next_tx(manager);
    let mut vault = s.take_shared<Vault<SUI>>();
    vault.set_security_by_manager(1, s.ctx());
    ts::return_shared(vault);

    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_451);
    let price_bps = 1597;
    let (coll_amount, debt_amount) = manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );
    assert!(coll_amount == deposit_amount);
    assert!(debt_amount == borrow_amount);

    scenario.end();
}

#[test, expected_failure(abort_code = vault::EAgainstSecurityLevel)]
fun test_set_manager_role_with_minor_level() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    // assign manager role
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    let manager = @234;
    vault.set_manager_role(&cap, manager, 2);
    ts::return_shared(vault);
    s.return_to_sender(cap);
    // toggle security to 2
    s.next_tx(manager);
    let mut vault = s.take_shared<Vault<SUI>>();
    vault.set_security_by_manager(2, s.ctx());
    ts::return_shared(vault);

    // deposit action is still allowed
    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_451);
    let price_bps = 1597;
    let (coll_amount, debt_amount) = manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );
    assert!(coll_amount == deposit_amount);
    assert!(debt_amount == borrow_amount);

    // pass 1 year
    time_pass(s, one_year());

    // liquidate
    let liquidator = @0xcafe;
    let price_bps = 1597;
    let out_amount = liquidate<SUI>(s, liquidator, user,
        option::none(),
        price_bps,
    );
    assert!(out_amount == coll_amount);

    scenario.end();
}

#[test]
fun test_set_manager_role_with_revoke_security_():Scenario{
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    // assign manager role
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    let manager = @234;
    vault.set_manager_role(&cap, manager, 2);
    ts::return_shared(vault);
    s.return_to_sender(cap);

    // create position without security check opened
    let user = @0x123;
    let deposit_amount = sui(10_000);
    let borrow_amount = usdb(1_451);
    let price_bps = 1597;
    let (coll_amount, debt_amount) = manage_position<SUI>(s, user,
        deposit_amount - 1,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );
    assert!(coll_amount == deposit_amount - 1);
    assert!(debt_amount == borrow_amount);

    // toggle security to 2
    s.next_tx(manager);
    let mut vault = s.take_shared<Vault<SUI>>();
    vault.set_security_by_manager(2, s.ctx());
    ts::return_shared(vault);

    // only allowed deposit action under security level 2
    let user = @0x123;
    let price_bps = 1597;
    let (coll_amount, debt_amount) = manage_position<SUI>(s, user,
        1,
        0, // the other actions is restricted
        0,
        0,
        option::some(price_bps),
    );
    assert!(coll_amount == deposit_amount);
    assert!(debt_amount == borrow_amount);

    // admin revoke security
    // set security back to 0
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    vault.set_security_by_admin(&cap, option::none(), s.ctx());
    ts::return_shared(vault);
    s.return_to_sender(cap);

    // pass 1 year
    time_pass(s, one_year());

    // liquidate
    let liquidator = @0xcafe;
    let price_bps = 1597;
    let out_amount = liquidate<SUI>(s, liquidator, user,
        option::none(),
        price_bps,
    );
    assert!(out_amount == coll_amount);

    scenario
}

#[test]
fun test_update_manager_role() {
    let mut scenario = test_set_manager_role_with_revoke_security_();
    let s = &mut scenario;

    // assign manager role
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    let manager = @234;
    vault.set_manager_role(&cap, manager, 1);
    ts::return_shared(vault);
    s.return_to_sender(cap);

    // toggle security to 2
    s.next_tx(manager);
    let mut vault = s.take_shared<Vault<SUI>>();
    vault.set_security_by_manager(1, s.ctx());
    ts::return_shared(vault);

    scenario.end();
}

#[test, expected_failure(abort_code = vault::ENotManager)]
fun test_remove_manager_role_not_manager_err() {
    let mut scenario = test_set_manager_role_with_revoke_security_();
    let s = &mut scenario;

    // admin revoke security
    // set security back to 0
    s.next_tx(admin());
    let mut vault = s.take_shared<Vault<SUI>>();
    let cap = s.take_from_sender<AdminCap>();
    let manager = @234;
    vault.remove_manager_role(&cap, manager);
    ts::return_shared(vault);
    s.return_to_sender(cap);

    // toggle security to 2
    s.next_tx(manager);
    let mut vault = s.take_shared<Vault<SUI>>();
    vault.set_security_by_manager(1, s.ctx());
    ts::return_shared(vault);

    scenario.end();
}

#[test]
fun test_long_term_position() {
    let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
    let mut scenario = setup<SUI, LiquidationRule>(9, supply_limit);
    let s = &mut scenario;

    let user = @0x123;
    let deposit_amount = sui(1_000_000);
    let borrow_amount = usdb(1_000);
    let price_bps = 1597;
    let (coll_amount, debt_amount) = manage_position<SUI>(s, user,
        deposit_amount,
        borrow_amount,
        0,
        0,
        option::some(price_bps),
    );
    assert!(coll_amount == deposit_amount);
    assert!(debt_amount == borrow_amount);

    // pass 1000 year
    let years = 1000;
    time_pass(s, years * one_year());

    // check position
    check_position<SUI>(s, user,
        true,
        deposit_amount,
        interest_rate().mul_u64(years).add_u64(1).mul_u64(borrow_amount).ceil(),
    );

    // donor deposit and repay
    let coll_donation_amount = sui(500);
    let usdb_donation_amount = interest_rate().mul_u64(years).mul_u64(borrow_amount).ceil();
    let (coll_amount, debt_amount) = donate<SUI>(s, user,
        coll_donation_amount,
        usdb_donation_amount,
    );
    assert!(coll_amount == deposit_amount + coll_donation_amount);
    assert!(debt_amount == borrow_amount);

    scenario.end();
}
