#[test_only]
/// Adversarial CDP conservation tests. Goal: make the vault mint USDB that is not
/// backed by debt, let a user profit across a full lifecycle, or break the
/// invariant that vault-minted USDB is always accounted for. Any failure = bug.
module bucket_v2_cdp::adversarial_cdp_tests {
    use bucket_v2_cdp::vault::{Self, Vault};
    use bucket_v2_cdp::bucket_v2_cdp_tests::{Self as cdp, LiquidationRule};
    use bucket_v2_usd::usdb::{Self, USDB, Treasury};
    use bucket_v2_cdp::witness::BucketV2CDP;
    use sui::sui::SUI;
    use sui::clock::Clock;
    use sui::test_scenario::{Self as ts, Scenario};

    fun treasury_usdb(treasury: &Treasury): u64 {
        if (!treasury.is_claimable_map_exists_type<USDB>()) { 0 }
        else {
            let map = treasury.claimable_map<USDB>();
            let w = std::type_name::get<BucketV2CDP>();
            if (map.contains(&w)) { map[&w].value() } else { 0 }
        }
    }

    /// Reads vault-minted supply, user's debt, and treasury-held interest USDB, and
    /// asserts the vault never mints MORE USDB than is accounted for by
    /// (outstanding debt + interest already realized to the treasury).
    fun assert_solvent(s: &mut Scenario, user: address) {
        s.next_tx(@0x0);
        let clock = s.take_shared<Clock>();
        let vault = s.take_shared<Vault<SUI>>();
        let treasury = s.take_shared<Treasury>();

        let minted = vault.limited_supply().supply();
        let (_coll, debt) = vault.get_position_data(user, &clock);
        let interest_in_treasury = treasury_usdb(&treasury);

        assert!(minted <= debt + interest_in_treasury, 8001);

        ts::return_shared(treasury);
        ts::return_shared(vault);
        ts::return_shared(clock);
    }

    /// SOLVENCY across an interest lifecycle: vault-minted USDB must stay accounted for.
    #[test]
    fun test_solvency_minted_equals_debt() {
        let supply_limit = 100_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = cdp::setup<SUI, LiquidationRule>(9, supply_limit);
        let s = &mut scenario;

        let user = @0x123;
        let (_,_) = cdp::manage_position<SUI>(s, user, cdp::sui(1_000_000), cdp::usdb(100_000), 0, 0, option::some(20000));
        assert_solvent(s, user);

        cdp::time_pass(s, cdp::one_year());
        let (_,_) = cdp::manage_position<SUI>(s, user, cdp::sui(1), 0, 0, 0, option::some(20000));
        assert_solvent(s, user);

        cdp::time_pass(s, cdp::one_year());
        let (_,_) = cdp::manage_position<SUI>(s, user, 0, 0, cdp::usdb(10_000), 0, option::some(20000));
        assert_solvent(s, user);
        scenario.end();
    }

    /// A full deposit->borrow->repay->withdraw cycle must net zero for the user
    /// (no free collateral, no USDB profit). manage_position internally asserts
    /// coll_out == withdraw and usdb_out == borrow each step.
    #[test]
    fun test_full_cycle_no_profit() {
        let supply_limit = 100_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = cdp::setup<SUI, LiquidationRule>(9, supply_limit);
        let s = &mut scenario;

        let user = @0xBAD;
        let deposit = cdp::sui(1_000);
        let borrow = cdp::usdb(500);
        let (coll_after, _d) =
            cdp::manage_position<SUI>(s, user, deposit, borrow, 0, 0, option::some(20000));
        assert!(coll_after == deposit, 8100);

        let (coll_after2, debt_after2) =
            cdp::manage_position<SUI>(s, user, 0, 0, borrow, deposit, option::some(20000));
        assert!(coll_after2 == 0, 8101);
        assert!(debt_after2 == 0, 8102);
        scenario.end();
    }
}
