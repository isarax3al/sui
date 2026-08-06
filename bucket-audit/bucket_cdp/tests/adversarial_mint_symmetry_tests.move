#[test_only]
/// H-01 empirical check: prove that across the borrow/repay branches of
/// `update_position`, the USDB minted equals the increase in the vault's tracked
/// debt/supply, and USDB burned equals the decrease — with no path where the
/// returned repayment (Case A) is double-counted into extra USDB.
module bucket_v2_cdp::adversarial_mint_symmetry_tests {
    use bucket_v2_cdp::vault::{Self, Vault};
    use bucket_v2_cdp::bucket_v2_cdp_tests::{Self as cdp, LiquidationRule, RequestCheck, ResponseCheck};
    use bucket_v2_usd::admin::AdminCap;
    use bucket_v2_usd::usdb::{Self, USDB, Treasury};
    use bucket_v2_usd::bucket_v2_usd_tests::admin;
    use bucket_v2_usd::limited_supply;
    use bucket_v2_framework::{float, account};
    use bucket_v2_oracle::result;
    use sui::sui::SUI;
    use sui::{coin::{Self, Coin}, clock::Clock, test_scenario::{Self as ts}};

    #[test]
    fun test_mint_debt_symmetry_borrow_with_repayment() {
        let supply_limit = 100_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = cdp::setup<SUI, LiquidationRule>(9, supply_limit);
        let s = &mut scenario;

        s.next_tx(admin());
        {
            let mut vault = s.take_shared<Vault<SUI>>();
            let cap = s.take_from_sender<AdminCap>();
            vault.remove_request_check<SUI, RequestCheck>(&cap);
            vault.remove_response_check<SUI, ResponseCheck>(&cap);
            ts::return_shared(vault);
            s.return_to_sender(cap);
        };

        let user = @0xd0d0;
        let price = result::new_for_testing<SUI>(float::from_bps(10000)); // $1

        // Op 1: deposit 1000 SUI, borrow 500 USDB (B=500, R=0).
        s.next_tx(user);
        let clock = s.take_shared<Clock>();
        let mut vault = s.take_shared<Vault<SUI>>();
        let mut treasury = s.take_shared<Treasury>();

        let supply_0 = vault.limited_supply().supply();
        let acc = account::request(s.ctx());
        let dep = coin::mint_for_testing<SUI>(cdp::sui(1_000), s.ctx());
        let req = vault.debtor_request(&acc, &treasury, dep, cdp::usdb(500), coin::zero(s.ctx()), 0);
        let (coll0, mut usdb_bal, res) = vault.update_position(
            &mut treasury, &clock, &option::some(price), req, s.ctx());
        vault.destroy_response(&treasury, res);
        coll0.destroy_zero();

        let (_, debt_1) = vault.get_position_data(user, &clock);
        let supply_1 = vault.limited_supply().supply();
        // borrowed 500, no repayment -> minted 500, debt 500
        assert!(usdb_bal.value() == cdp::usdb(500), 1001);
        assert!(supply_1 - supply_0 == cdp::usdb(500), 1002);
        assert!(debt_1 == cdp::usdb(500), 1003);

        // Op 2: borrow 300 MORE, but hand back 100 USDB as repayment (Case A: B>R).
        // Expected: usdb_out = 300 (200 minted + 100 returned); minted delta = 200; debt delta = 200.
        s.next_tx(user);
        let repay_coin: Coin<USDB> = usdb_bal.split(cdp::usdb(100), s.ctx());
        let acc2 = account::request(s.ctx());
        let req2 = vault.debtor_request(&acc2, &treasury, coin::zero(s.ctx()), cdp::usdb(300), repay_coin, 0);
        let (coll1, usdb_out2, res2) = vault.update_position(
            &mut treasury, &clock, &option::some(price), req2, s.ctx());
        vault.destroy_response(&treasury, res2);
        coll1.destroy_zero();

        let (_, debt_2) = vault.get_position_data(user, &clock);
        let supply_2 = vault.limited_supply().supply();

        // The output equals the full borrow (returned repayment joined in), NOT more.
        assert!(usdb_out2.value() == cdp::usdb(300), 1004);
        // Net minted this op = 300 - 100 = 200 (repayment was NOT re-minted).
        assert!(supply_2 - supply_1 == cdp::usdb(200), 1005);
        // Debt increased by exactly the net borrow = 200.
        assert!(debt_2 - debt_1 == cdp::usdb(200), 1006);
        // Symmetry: minted delta == debt delta.
        assert!(supply_2 - supply_1 == debt_2 - debt_1, 1007);

        usdb_bal.join(usdb_out2);
        usdb_bal.burn_for_testing();
        ts::return_shared(clock);
        ts::return_shared(vault);
        ts::return_shared(treasury);
        scenario.end();
    }

    #[test]
    fun test_burn_debt_symmetry_on_repay() {
        let supply_limit = 100_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = cdp::setup<SUI, LiquidationRule>(9, supply_limit);
        let s = &mut scenario;

        s.next_tx(admin());
        {
            let mut vault = s.take_shared<Vault<SUI>>();
            let cap = s.take_from_sender<AdminCap>();
            vault.remove_request_check<SUI, RequestCheck>(&cap);
            vault.remove_response_check<SUI, ResponseCheck>(&cap);
            ts::return_shared(vault);
            s.return_to_sender(cap);
        };

        let user = @0xd0d1;
        let price = result::new_for_testing<SUI>(float::from_bps(10000));

        s.next_tx(user);
        let clock = s.take_shared<Clock>();
        let mut vault = s.take_shared<Vault<SUI>>();
        let mut treasury = s.take_shared<Treasury>();

        // Borrow 600 against 1000 SUI.
        let acc = account::request(s.ctx());
        let dep = coin::mint_for_testing<SUI>(cdp::sui(1_000), s.ctx());
        let req = vault.debtor_request(&acc, &treasury, dep, cdp::usdb(600), coin::zero(s.ctx()), 0);
        let (coll0, usdb_bal, res) = vault.update_position(
            &mut treasury, &clock, &option::some(price), req, s.ctx());
        vault.destroy_response(&treasury, res);
        coll0.destroy_zero();

        let (_, debt_1) = vault.get_position_data(user, &clock);
        let supply_1 = vault.limited_supply().supply();
        assert!(debt_1 == cdp::usdb(600), 2001);

        // Repay 200 (B=0, R=200). No pending interest here, so all 200 is burned.
        s.next_tx(user);
        let mut hold = usdb_bal;
        let repay_coin: Coin<USDB> = hold.split(cdp::usdb(200), s.ctx());
        let acc2 = account::request(s.ctx());
        let req2 = vault.debtor_request(&acc2, &treasury, coin::zero(s.ctx()), 0, repay_coin, 0);
        // pure repay -> no CR check -> no price needed
        let (coll1, usdb_out2, res2) = vault.update_position(
            &mut treasury, &clock, &option::none(), req2, s.ctx());
        vault.destroy_response(&treasury, res2);
        coll1.destroy_zero();
        usdb_out2.destroy_zero(); // B=0 -> nothing out

        let (_, debt_2) = vault.get_position_data(user, &clock);
        let supply_2 = vault.limited_supply().supply();

        // Debt decreased by exactly 200, and supply (minted) decreased by exactly 200.
        assert!(debt_1 - debt_2 == cdp::usdb(200), 2002);
        assert!(supply_1 - supply_2 == cdp::usdb(200), 2003);
        assert!(debt_1 - debt_2 == supply_1 - supply_2, 2004);

        hold.burn_for_testing();
        ts::return_shared(clock);
        ts::return_shared(vault);
        ts::return_shared(treasury);
        scenario.end();
    }
}
