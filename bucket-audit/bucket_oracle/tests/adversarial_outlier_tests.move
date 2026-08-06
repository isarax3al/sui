#[test_only]
/// Adversarial oracle test: the outlier filter compares each price to the WEIGHTED
/// MEAN, which is itself skewed by the outlier. A source with enough weight pulls
/// the mean toward its (anomalous) price, so the HONEST sources are flagged as
/// outliers and removed, while the anomalous one survives. The "anomaly filter"
/// therefore AMPLIFIES the anomaly instead of filtering it.
module bucket_v2_oracle::adversarial_outlier_tests {
    use sui::test_scenario::{Self as ts};
    use sui::sui::SUI;
    use bucket_v2_framework::float::{Self, Float};
    use bucket_v2_oracle::aggregator::{Self, PriceAggregator};
    use bucket_v2_oracle::listing::{Self, ListingCap};
    use bucket_v2_oracle::collector;

    public struct HonestA has drop {}
    public struct HonestB has drop {}
    public struct Rogue has drop {}

    public struct Primary has drop {}
    public struct BackupA has drop {}
    public struct BackupB has drop {}

    // Two-source witnesses for the precise boundary characterization below.
    public struct Dominant has drop {}
    public struct Backup has drop {}

    /// Build a 2-source aggregator (one Dominant, one Backup), collect one price
    /// each, and return the aggregated price. Aborts (inside `aggregate`) if the
    /// filter removes every source (both outside tolerance of the skewed mean).
    fun run_two_source(
        dominant_w: u8,
        backup_w: u8,
        dominant_bps: u64,
        backup_bps: u64,
        tolerance_bps: u64,
    ): Float {
        let dev = @0xde1;
        let mut scenario = ts::begin(dev);
        let s = &mut scenario;
        listing::init_for_testing(s.ctx());

        s.next_tx(dev);
        let mut cap = s.take_from_sender<ListingCap>();
        // weight_threshold = 2: a lone survivor (weight >= 2) still aggregates,
        // so an empty survivor set is the only way to hit the threshold abort.
        aggregator::create<SUI>(&mut cap, 2, tolerance_bps, s.ctx());
        s.return_to_sender(cap);

        s.next_tx(dev);
        let cap = s.take_from_sender<ListingCap>();
        let mut agg = s.take_shared<PriceAggregator<SUI>>();
        agg.set_rule_weight<SUI, Dominant>(&cap, dominant_w);
        agg.set_rule_weight<SUI, Backup>(&cap, backup_w);
        s.return_to_sender(cap);
        ts::return_shared(agg);

        s.next_tx(@0xcafe);
        let agg = s.take_shared<PriceAggregator<SUI>>();
        let mut c = collector::new<SUI>();
        c.collect(Dominant {}, option::some(float::from_bps(dominant_bps)));
        c.collect(Backup {}, option::some(float::from_bps(backup_bps)));
        let r = agg.aggregate(c).aggregated_price();
        ts::return_shared(agg);
        scenario.end();
        r
    }

    /// REALISTIC scenario: a "primary + 2 backups" oracle. The primary holds the
    /// majority weight (typical: it's the trusted feed, backups are sanity checks).
    /// When the primary deviates (manipulation / lag / volatility), the mean-based
    /// filter discards BOTH honest backups -- exactly when they are needed -- and
    /// lets the primary's deviated price stand alone. Multi-source safety is nullified.
    #[test]
    fun test_majority_primary_deviation_discards_backups() {
        let dev = @0xde1;
        let mut scenario = ts::begin(dev);
        let s = &mut scenario;
        listing::init_for_testing(s.ctx());

        s.next_tx(dev);
        let mut cap = s.take_from_sender<ListingCap>();
        aggregator::create<SUI>(&mut cap, 2, 1000 /* 10% tolerance */, s.ctx());
        s.return_to_sender(cap);

        // Primary weight 4 (67%), two backups weight 1 each.
        s.next_tx(dev);
        let cap = s.take_from_sender<ListingCap>();
        let mut agg = s.take_shared<PriceAggregator<SUI>>();
        agg.set_rule_weight<SUI, Primary>(&cap, 4);
        agg.set_rule_weight<SUI, BackupA>(&cap, 1);
        agg.set_rule_weight<SUI, BackupB>(&cap, 1);
        s.return_to_sender(cap);
        ts::return_shared(agg);

        // Backups correctly report $1.00; the primary deviates to $1.30 (30% high).
        s.next_tx(@0xcafe);
        let agg = s.take_shared<PriceAggregator<SUI>>();
        let mut c = collector::new<SUI>();
        c.collect(Primary {}, option::some(float::from_bps(1_3000)));   // $1.30
        c.collect(BackupA {}, option::some(float::from_bps(1_0000)));   // $1.00
        c.collect(BackupB {}, option::some(float::from_bps(1_0000)));   // $1.00
        let result = agg.aggregate(c).aggregated_price();
        ts::return_shared(agg);

        // mean = (1.30*4 + 1.00 + 1.00)/6 = 1.20
        //   backups: |1.20-1.00|/1.20 = 0.167 > 0.10  -> BOTH BACKUPS REMOVED
        //   primary: |1.20-1.30|/1.20 = 0.083 < 0.10  -> primary KEPT
        //   result  = 1.30  (the primary's deviated price, backups discarded)
        // A robust median filter would output $1.00 and flag the primary.
        assert!(result.eq(float::from_bps(1_3000)), 9201);
        scenario.end();
    }

    #[test]
    fun test_outlier_filter_amplifies_anomaly() {
        let dev = @0xde1;
        let mut scenario = ts::begin(dev);
        let s = &mut scenario;
        listing::init_for_testing(s.ctx());

        // tolerance 10% (1000 bps), threshold low
        let weight_threshold = 2;
        let outlier_tolerance_bps = 1000;
        s.next_tx(dev);
        let mut cap = s.take_from_sender<ListingCap>();
        aggregator::create<SUI>(&mut cap, weight_threshold, outlier_tolerance_bps, s.ctx());
        s.return_to_sender(cap);

        // Two honest sources (weight 1 each) + one heavily-weighted source (weight 10).
        s.next_tx(dev);
        let cap = s.take_from_sender<ListingCap>();
        let mut agg = s.take_shared<PriceAggregator<SUI>>();
        agg.set_rule_weight<SUI, HonestA>(&cap, 1);
        agg.set_rule_weight<SUI, HonestB>(&cap, 1);
        agg.set_rule_weight<SUI, Rogue>(&cap, 10);
        s.return_to_sender(cap);
        ts::return_shared(agg);

        // Honest sources agree on price 100; the rogue reports 200 (2x anomaly).
        s.next_tx(@0xcafe);
        let agg = s.take_shared<PriceAggregator<SUI>>();
        let mut c = collector::new<SUI>();
        c.collect(HonestA {}, option::some(float::from(100)));
        c.collect(HonestB {}, option::some(float::from(100)));
        c.collect(Rogue {}, option::some(float::from(200)));
        let result = agg.aggregate(c).aggregated_price();
        ts::return_shared(agg);

        // The honest consensus is 100. A robust (median-based) filter would output ~100
        // and drop the 200 outlier. Instead:
        //   weighted_mean = (100*1 + 100*1 + 200*10)/12 = 183.33
        //   honest deviation  |183.33-100|/183.33 = 0.454 > 0.10  -> HONEST REMOVED
        //   rogue  deviation  |183.33-200|/183.33 = 0.091 < 0.10  -> ROGUE KEPT
        //   final = 200  (pure rogue; honest tempering removed)
        //
        // Prove the anomaly (200) dominated and the honest 100 was filtered out.
        assert!(result.eq(float::from(200)), 9101);
        // And prove it's even WORSE than doing no filtering (which would give 183.33):
        // the filter increased the rogue's influence from 183.33 to 200.
        assert!(result.gt(float::from(183)), 9102);
        scenario.end();
    }

    /// DIMENSION 1 (weight): fix the deviation at 22% and sweep the dominant
    /// source's weight across the 50% boundary. Only a strict majority (>50%)
    /// lets the deviating source survive while the honest one is filtered.
    ///
    /// At weight f and deviation d (honest = 1.0), mean m = 1 + f*d, and the
    /// relative distance from m is (f*d) for the honest source and ((1-f)*d) for
    /// the dominant source. The dominant source is the *closer* one (kept) iff
    /// (1-f) < f, i.e. f > 50%. With d = 22%, tol = 10%:
    #[test]
    fun test_weight_boundary_around_half() {
        // f = 49% (dominant weight 49, honest 51): dominant is the FARTHER source
        //   -> correctly rejected; honest 1.00 stands. This is the intended behavior.
        let r49 = run_two_source(49, 51, 12200, 10000, 1000);
        assert!(r49.eq(float::from_bps(10000)), 9110);

        // f = 50% (50/50): distances are equal, both stay within tolerance
        //   -> both kept, result is the tempered mean 1.11 (no flip possible at 50%).
        let r50 = run_two_source(50, 50, 12200, 10000, 1000);
        assert!(r50.eq(float::from_bps(11100)), 9111);
        assert!(r50.lt(float::from_bps(12200)) && r50.gt(float::from_bps(10000)), 9112);

        // f = 51% (51/49): dominant is now the CLOSER source; the honest 1.00 is
        //   flagged as the outlier and removed -> result is the deviated 1.22 alone.
        let r51 = run_two_source(51, 49, 12200, 10000, 1000);
        assert!(r51.eq(float::from_bps(12200)), 9113);
    }

    /// DIMENSION 2 (deviation): fix the dominant weight at 60% and sweep the
    /// deviation through the three regimes. Derived window for f=0.6, tol=0.1:
    ///   d <= 18.52%          -> both kept, result = skewed mean (mild).
    ///   18.52% < d <= 29.41% -> honest removed, deviated price stands ALONE (danger).
    ///   d > 29.41%           -> deviated source also removed -> abort (liveness).
    #[test]
    fun test_deviation_below_window_yields_mean() {
        // d = 10% (below 18.52%): honest survives, so the result is only mildly
        // skewed (mean 1.06), strictly less than the deviated 1.10 -> tempered.
        let r = run_two_source(60, 40, 11000, 10000, 1000);
        assert!(r.eq(float::from_bps(10600)), 9120);
        assert!(r.lt(float::from_bps(11000)), 9121);
    }

    #[test]
    fun test_deviation_inside_window_full_flip() {
        // d = 25% (inside the window): the honest 1.00 is discarded and the
        // deviated 1.25 becomes the sole aggregated price -> maximal error.
        let r = run_two_source(60, 40, 12500, 10000, 1000);
        assert!(r.eq(float::from_bps(12500)), 9122);
    }

    #[test, expected_failure(abort_code = aggregator::ETotalWeightNotEnough)]
    fun test_deviation_above_window_aborts() {
        // d = 40% (above 29.41%): both sources fall outside tolerance of the
        // skewed mean, every source is filtered, and aggregation aborts. This is
        // a liveness failure (price feed stalls), not a wrong price.
        let _r = run_two_source(60, 40, 14000, 10000, 1000);
    }

    /// The complete-flip precondition (a single source with > 50% weight) is not
    /// a contrived state that requires patching the contract: it is an officially
    /// supported configuration. `set_rule_weight` accepts any u8 and enforces NO
    /// per-source cap and NO "honest majority" invariant. This test builds the
    /// canonical "primary 60% + two 20% backups" topology through the public API
    /// and shows initialization + a normal aggregation both succeed.
    #[test]
    fun test_configuration_accepts_majority_weight_source() {
        let dev = @0xde1;
        let mut scenario = ts::begin(dev);
        let s = &mut scenario;
        listing::init_for_testing(s.ctx());

        s.next_tx(dev);
        let mut cap = s.take_from_sender<ListingCap>();
        aggregator::create<SUI>(&mut cap, 2, 1000, s.ctx());
        s.return_to_sender(cap);

        // Primary 60%, BackupA 20%, BackupB 20% -- a single source owns a strict
        // majority of the total weight. No abort, no validation rejects this.
        s.next_tx(dev);
        let cap = s.take_from_sender<ListingCap>();
        let mut agg = s.take_shared<PriceAggregator<SUI>>();
        agg.set_rule_weight<SUI, Primary>(&cap, 60);
        agg.set_rule_weight<SUI, BackupA>(&cap, 20);
        agg.set_rule_weight<SUI, BackupB>(&cap, 20);
        s.return_to_sender(cap);
        ts::return_shared(agg);

        // And the config is fully operational: an all-honest round aggregates fine.
        s.next_tx(@0xcafe);
        let agg = s.take_shared<PriceAggregator<SUI>>();
        let mut c = collector::new<SUI>();
        c.collect(Primary {}, option::some(float::from_bps(10000)));
        c.collect(BackupA {}, option::some(float::from_bps(10000)));
        c.collect(BackupB {}, option::some(float::from_bps(10000)));
        let r = agg.aggregate(c).aggregated_price();
        assert!(r.eq(float::from_bps(10000)), 9131);
        ts::return_shared(agg);
        scenario.end();
    }

    /// The `> 50%` precondition is over the ACTIVE (price-returning) sources, NOT
    /// the total registered weight. `remove_outliers` drops sources that report
    /// `none` (a stale/unavailable feed reports `option::none()` yet is still
    /// "collected"), then computes the mean over the survivors. So a source whose
    /// STATIC weight is a minority can become a majority of the active set whenever
    /// enough other sources are inactive — and dominate the aggregate.
    ///
    /// Config: A=40, B=30, C=30 (no source exceeds 50% of the total 100). But if C
    /// is inactive, A holds 40/(40+30) = 57.1% of the active weight and, deviating
    /// 22%, filters out the honest B.
    #[test]
    fun test_inactive_source_lets_minority_weight_dominate() {
        let dev = @0xde1;
        let mut scenario = ts::begin(dev);
        let s = &mut scenario;
        listing::init_for_testing(s.ctx());

        s.next_tx(dev);
        let mut cap = s.take_from_sender<ListingCap>();
        aggregator::create<SUI>(&mut cap, 2, 1000, s.ctx());
        s.return_to_sender(cap);

        s.next_tx(dev);
        let cap = s.take_from_sender<ListingCap>();
        let mut agg = s.take_shared<PriceAggregator<SUI>>();
        agg.set_rule_weight<SUI, Primary>(&cap, 40);  // minority of the registered total
        agg.set_rule_weight<SUI, BackupA>(&cap, 30);
        agg.set_rule_weight<SUI, BackupB>(&cap, 30);
        s.return_to_sender(cap);
        ts::return_shared(agg);

        s.next_tx(@0xcafe);
        let agg = s.take_shared<PriceAggregator<SUI>>();
        let mut c = collector::new<SUI>();
        c.collect(Primary {}, option::some(float::from_bps(12200)));  // deviates +22%
        c.collect(BackupA {}, option::some(float::from_bps(10000)));  // honest
        c.collect(BackupB {}, option::none());                        // inactive feed
        let r = agg.aggregate(c).aggregated_price();
        ts::return_shared(agg);

        // Active mean = (1.22*40 + 1.00*30)/70 = 1.1257; honest B is 11.2% away (removed),
        // deviating A is 8.4% away (kept) -> aggregate resolves to the deviated 1.22.
        assert!(r.eq(float::from_bps(12200)), 9140);
        scenario.end();
    }

    /// CRITICAL PRECONDITION: `weight_threshold` is checked AFTER outlier removal
    /// (aggregate() L203-206), on the SURVIVORS. So an active-majority flip only
    /// returns a wrong PRICE if the deviating source's OWN weight >= threshold;
    /// otherwise, once the honest sources are filtered out, the lone survivor
    /// fails the threshold and the call ABORTS (liveness, not a wrong price).
    ///
    /// Same 40/30/30 geometry as above, but threshold = 50: A becomes 57% of the
    /// active weight and filters out honest B, yet the surviving weight (40) is
    /// below 50 -> abort. This is why "active majority" alone is necessary but not
    /// sufficient for a single-source complete flip.
    #[test, expected_failure(abort_code = aggregator::ETotalWeightNotEnough)]
    fun test_flip_below_threshold_aborts_not_wrong_price() {
        let dev = @0xde1;
        let mut scenario = ts::begin(dev);
        let s = &mut scenario;
        listing::init_for_testing(s.ctx());

        s.next_tx(dev);
        let mut cap = s.take_from_sender<ListingCap>();
        aggregator::create<SUI>(&mut cap, 50, 1000, s.ctx());  // threshold = 50
        s.return_to_sender(cap);

        s.next_tx(dev);
        let cap = s.take_from_sender<ListingCap>();
        let mut agg = s.take_shared<PriceAggregator<SUI>>();
        agg.set_rule_weight<SUI, Primary>(&cap, 40);
        agg.set_rule_weight<SUI, BackupA>(&cap, 30);
        agg.set_rule_weight<SUI, BackupB>(&cap, 30);
        s.return_to_sender(cap);
        ts::return_shared(agg);

        s.next_tx(@0xcafe);
        let agg = s.take_shared<PriceAggregator<SUI>>();
        let mut c = collector::new<SUI>();
        c.collect(Primary {}, option::some(float::from_bps(12200)));  // survives filter, weight 40
        c.collect(BackupA {}, option::some(float::from_bps(10000)));  // filtered out
        c.collect(BackupB {}, option::none());                        // inactive
        let _r = agg.aggregate(c).aggregated_price();  // survivor weight 40 < 50 -> abort
        ts::return_shared(agg);
        scenario.end();
    }
}
