#[test_only]
/// Adversarial oracle test: the outlier filter compares each price to the WEIGHTED
/// MEAN, which is itself skewed by the outlier. A source with enough weight pulls
/// the mean toward its (anomalous) price, so the HONEST sources are flagged as
/// outliers and removed, while the anomalous one survives. The "anomaly filter"
/// therefore AMPLIFIES the anomaly instead of filtering it.
module bucket_v2_oracle::adversarial_outlier_tests {
    use sui::test_scenario::{Self as ts};
    use sui::sui::SUI;
    use bucket_v2_framework::float;
    use bucket_v2_oracle::aggregator::{Self, PriceAggregator};
    use bucket_v2_oracle::listing::{Self, ListingCap};
    use bucket_v2_oracle::collector;

    public struct HonestA has drop {}
    public struct HonestB has drop {}
    public struct Rogue has drop {}

    public struct Primary has drop {}
    public struct BackupA has drop {}
    public struct BackupB has drop {}

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
}
