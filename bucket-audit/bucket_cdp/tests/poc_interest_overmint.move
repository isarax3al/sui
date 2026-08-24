#[test_only]
/// PoC — BucketV2 CDP: interest-accrual rounding mints UNBACKED USDB and
/// permanently inflates the vault supply counter.
///
/// Drop this file into `bucket_cdp/tests/` and run:
///     sui move test poc_phantom
/// It passes, proving the buggy state. It uses ONLY public functions — no
/// modification to the protocol source is required.
///
/// Root cause (bucket_cdp/sources/vault.move):
///   `collect_interest` runs on every position touch and accrues the whole
///   vault, rounding the aggregate base UP each time:
///       total_interest   = ceil(unit_diff * total_debt_amount)
///       total_debt_amount += total_interest
///       mint_usdb(total_interest) -> treasury            // real USDB minted
///   Each position separately accrues ceil(pos_unit_diff * pos_debt). Because
///   `collect_interest` fires far more often than any single position is touched
///   and always rounds the larger aggregate UP, the minted-to-treasury interest
///   drifts strictly ABOVE the sum of what borrowers actually owe. Borrowers only
///   repay/burn their per-position amounts, so the surplus that was minted is
///   never burned.
///
/// Impact after every position is fully repaid and closed (real debt == 0,
/// collateral == 0):
///   1. `vault.limited_supply().supply()` is left > 0 and is NEVER reclaimed, so
///      the vault's borrow capacity is permanently consumed. Repeated over the
///      protocol's life this monotonically climbs toward the supply limit and
///      eventually bricks all borrowing (availability / DoS).
///   2. USDB total supply is left > its starting value with ZERO collateral
///      backing it (the surplus sits in the treasury as "interest"): unbacked
///      mint / peg dilution.
module bucket_v2_cdp::poc_interest_overmint {
    use sui::clock::{Self, Clock};
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::sui::SUI;
    use sui::coin::{Self};
    use bucket_v2_framework::float;
    use bucket_v2_framework::double;
    use bucket_v2_framework::account;
    use bucket_v2_oracle::result as price_result;
    use bucket_v2_usd::bucket_v2_usd_tests::{Self, admin};
    use bucket_v2_usd::admin::AdminCap;
    use bucket_v2_usd::usdb::{Self, USDB, Treasury};
    use bucket_v2_usd::limited_supply;
    use bucket_v2_cdp::witness::BucketV2CDP;
    use bucket_v2_cdp::vault::{Self, Vault};

    public struct LiquidationRule has drop {}

    fun start_ts(): u64 { 1745301421843 }
    fun one_year(): u64 { 31_536_000_000 }
    fun sui(a: u64): u64 { a * 1_000_000_000 }
    fun usdb(a: u64): u64 { a * 10u64.pow(usdb::decimal()) }

    fun setup(): Scenario {
        let supply_limit = 100_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = bucket_v2_usd_tests::setup<BucketV2CDP>(1, supply_limit);
        let s = &mut scenario;
        s.next_tx(admin());
        let cap = s.take_from_sender<AdminCap>();
        let treasury = s.take_shared<Treasury>();
        let mut clock = clock::create_for_testing(s.ctx());
        clock.set_for_testing(start_ts());
        let vault = vault::new<SUI, LiquidationRule>(
            &treasury, &cap, 9, double::from_bps(5_50), supply_limit, float::from_percent(110), s.ctx(),
        );
        transfer::public_share_object(vault);
        clock.share_for_testing();
        s.return_to_sender(cap);
        ts::return_shared(treasury);
        scenario
    }

    fun tick(s: &mut Scenario, dt: u64) {
        s.next_tx(@0x0);
        let mut clock = s.take_shared<Clock>();
        clock.increment_for_testing(dt);
        ts::return_shared(clock);
    }

    fun manage(
        s: &mut Scenario, user: address,
        deposit: u64, borrow: u64, repay: u64, withdraw: u64, price_bps: Option<u64>,
    ) {
        s.next_tx(user);
        let clock = s.take_shared<Clock>();
        let mut vault = s.take_shared<Vault<SUI>>();
        let mut treasury = s.take_shared<Treasury>();
        let acc = account::request(s.ctx());
        let dep = coin::mint_for_testing<SUI>(deposit, s.ctx());
        let rep = coin::mint_for_testing<USDB>(repay, s.ctx());
        let req = vault.debtor_request(&acc, &treasury, dep, borrow, rep, withdraw);
        let price_opt = price_bps.map!(|p| price_result::new_for_testing<SUI>(float::from_bps(p)));
        let (coll_coin, usdb_coin, res) = vault.update_position(&mut treasury, &clock, &price_opt, req, s.ctx());
        vault.destroy_response(&treasury, res);
        coll_coin.burn_for_testing();
        usdb_coin.burn_for_testing();
        ts::return_shared(clock);
        ts::return_shared(vault);
        ts::return_shared(treasury);
    }

    fun read_debt(s: &mut Scenario, user: address): u64 {
        s.next_tx(@0x0);
        let clock = s.take_shared<Clock>();
        let vault = s.take_shared<Vault<SUI>>();
        let (_, d) = vault.try_get_position_data(user, &clock);
        ts::return_shared(clock);
        ts::return_shared(vault);
        d
    }

    fun usdb_supply(s: &mut Scenario): u64 {
        s.next_tx(@0x0);
        let treasury = s.take_shared<Treasury>();
        let v = treasury.total_supply();
        ts::return_shared(treasury);
        v
    }

    // public accessor path: vault.limited_supply() -> &LimitedSupply -> .supply()
    fun vault_supply_counter(s: &mut Scenario): u64 {
        s.next_tx(@0x0);
        let vault = s.take_shared<Vault<SUI>>();
        let v = limited_supply::supply(vault.limited_supply());
        ts::return_shared(vault);
        v
    }

    #[test]
    fun poc_phantom_supply_and_unbacked_usdb() {
        let mut scenario = setup();
        let s = &mut scenario;
        let a = @0xA; let b = @0xB; let c = @0xC;

        let supply_before = usdb_supply(s);

        manage(s, a, sui(1000), usdb(333), 0, 0, option::some(20000));
        manage(s, b, sui(1000), usdb(777), 0, 0, option::some(20000));
        manage(s, c, sui(1000), usdb(101), 0, 0, option::some(20000));

        // accrue interest over ~2 years, touching positions at staggered times
        let mut i = 0;
        while (i < 4) {
            tick(s, one_year() / 12);
            manage(s, a, 0, 0, 0, 0, option::none());
            tick(s, one_year() / 12);
            manage(s, b, 0, 0, 0, 0, option::none());
            manage(s, c, 0, 0, 0, 0, option::none());
            i = i + 1;
        };

        // every borrower repays EXACTLY what they owe and withdraws all collateral
        let da = read_debt(s, a);
        manage(s, a, 0, 0, da, sui(1000), option::none());
        let db = read_debt(s, b);
        manage(s, b, 0, 0, db, sui(1000), option::none());
        let dc = read_debt(s, c);
        manage(s, c, 0, 0, dc, sui(1000), option::none());

        // ---- state after all debt is repaid and all collateral withdrawn ----
        s.next_tx(@0x0);
        let vault = s.take_shared<Vault<SUI>>();
        assert!(!vault.position_exists(a), 0);
        assert!(!vault.position_exists(b), 0);
        assert!(!vault.position_exists(c), 0);
        ts::return_shared(vault);

        let phantom_supply = vault_supply_counter(s);   // should be 0
        let unbacked_usdb = usdb_supply(s) - supply_before; // should be 0

        std::debug::print(&b"phantom vault limited_supply.supply (must be 0):".to_string());
        std::debug::print(&phantom_supply);
        std::debug::print(&b"USDB minted with no collateral backing (must be 0):".to_string());
        std::debug::print(&unbacked_usdb);

        // === THE BUG ===
        // Zero open positions and zero collateral, yet the vault supply counter is
        // stuck > 0 and USDB was minted that nothing backs.
        assert!(phantom_supply > 0, 1);
        assert!(unbacked_usdb > 0, 2);
        assert!(phantom_supply == unbacked_usdb, 3);

        scenario.end();
    }
}
