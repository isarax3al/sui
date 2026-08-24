#[test_only]
module bucket_v2_oracle::bucket_v2_oracle_tests;

use sui::test_scenario::{Self as ts};
use sui::sui::{SUI};
use bucket_v2_framework::float;
use bucket_v2_oracle::aggregator::{Self, PriceAggregator};
use bucket_v2_oracle::listing::{Self, ListingCap};
use bucket_v2_oracle::collector;

public struct PriceSourceA has drop {}

public struct PriceSourceB has drop {}

public struct PriceSourceC has drop {}

public struct PriceSourceM has drop {}

#[test]
fun test_bucket_v2_oracle() {
    let dev = @0xde1;
    let mut scenario = ts::begin(dev);
    let s = &mut scenario;
    listing::init_for_testing(s.ctx());

    let weight_threshold = 2;
    let outlier_tolerance_bps = 50_00;
    s.next_tx(dev);
    let mut cap = s.take_from_sender<ListingCap>();
    aggregator::create<SUI>(&mut cap, weight_threshold, outlier_tolerance_bps, s.ctx());
    s.return_to_sender(cap);

    s.next_tx(dev);
    let cap = s.take_from_sender<ListingCap>();
    let mut sui_agg = s.take_shared<PriceAggregator<SUI>>();
    sui_agg.set_rule_weight<SUI, PriceSourceA>(&cap, 2);
    sui_agg.set_rule_weight<SUI, PriceSourceB>(&cap, 1);
    sui_agg.set_rule_weight<SUI, PriceSourceC>(&cap, 1);
    s.return_to_sender(cap);
    ts::return_shared(sui_agg);

    let user = @0xcafe;
    s.next_tx(user);
    let sui_agg = s.take_shared<PriceAggregator<SUI>>();
    let mut collector = collector::new<SUI>();
    collector.collect(PriceSourceA {}, option::some(float::from_bps(3_5120)));
    collector.collect(PriceSourceB {}, option::none());
    collector.collect(PriceSourceC {}, option::none());
    let price_result = sui_agg.aggregate(collector);
    assert!(price_result.aggregated_price() == float::from_bps(3_5120));
    ts::return_shared(sui_agg);

    s.next_tx(user);
    let sui_agg = s.take_shared<PriceAggregator<SUI>>();
    let mut collector = collector::new<SUI>();
    collector.collect(PriceSourceA {}, option::none());
    collector.collect(PriceSourceB {}, option::some(float::from_bps(2_0000)));
    collector.collect(PriceSourceB {}, option::some(float::from_bps(3_4000)));
    collector.collect(PriceSourceC {}, option::some(float::from_bps(3_6000)));
    collector.collect(PriceSourceM {}, option::some(float::from_bps(4_0000)));
    let price_result = sui_agg.aggregate(collector);
    assert!(price_result.aggregated_price() == float::from_bps(3_5000));
    ts::return_shared(sui_agg);

    scenario.end();
}

#[test, expected_failure(abort_code = listing::EAlreadyListed)]
fun test_coin_type_already_listed() {
    let dev = @0xde1;
    let mut scenario = ts::begin(dev);
    let s = &mut scenario;
    listing::init_for_testing(s.ctx());

    s.next_tx(dev);
    let mut cap = s.take_from_sender<ListingCap>();
    aggregator::create<SUI>(&mut cap, 2, 100, s.ctx());
    aggregator::create<SUI>(&mut cap, 3, 100, s.ctx());
    s.return_to_sender(cap);

    scenario.end();
}

#[test, expected_failure(abort_code = aggregator::ETotalWeightNotEnough)]
fun test_total_weight_not_enough() {
    let dev = @0xde1;
    let mut scenario = ts::begin(dev);
    let s = &mut scenario;
    listing::init_for_testing(s.ctx());

    let weight_threshold = 2;
    let outlier_tolerance_bps = 100;
    s.next_tx(dev);
    let mut cap = s.take_from_sender<ListingCap>();
    aggregator::create<SUI>(&mut cap, weight_threshold, outlier_tolerance_bps, s.ctx());
    s.return_to_sender(cap);

    s.next_tx(dev);
    let cap = s.take_from_sender<ListingCap>();
    let mut sui_agg = s.take_shared<PriceAggregator<SUI>>();
    sui_agg.set_rule_weight<SUI, PriceSourceA>(&cap, 1);
    sui_agg.set_rule_weight<SUI, PriceSourceA>(&cap, 2);
    sui_agg.set_rule_weight<SUI, PriceSourceB>(&cap, 1);
    sui_agg.set_rule_weight<SUI, PriceSourceC>(&cap, 1);
    sui_agg.set_rule_weight<SUI, PriceSourceM>(&cap, 10);
    sui_agg.set_rule_weight<SUI, PriceSourceM>(&cap, 0);
    s.return_to_sender(cap);
    ts::return_shared(sui_agg);

    let user = @0xcafe;
    s.next_tx(user);
    let sui_agg = s.take_shared<PriceAggregator<SUI>>();
    let mut collector = collector::new<SUI>();
    collector.collect(PriceSourceA {}, option::some(float::from_bps(3_5120)));
    collector.collect(PriceSourceB {}, option::none());
    collector.collect(PriceSourceC {}, option::none());
    let price_result = sui_agg.aggregate(collector);
    assert!(price_result.aggregated_price() == float::from_bps(3_5120));
    ts::return_shared(sui_agg);

    s.next_tx(dev);
    let cap = s.take_from_sender<ListingCap>();
    let mut sui_agg = s.take_shared<PriceAggregator<SUI>>();
    sui_agg.set_weight_threshold(&cap, 5);
    s.return_to_sender(cap);
    ts::return_shared(sui_agg);

    s.next_tx(user);
    let sui_agg = s.take_shared<PriceAggregator<SUI>>();
    let mut collector = collector::new<SUI>();
    collector.collect(PriceSourceA {}, option::some(float::from_bps(3_5000)));
    collector.collect(PriceSourceB {}, option::some(float::from_bps(3_4000)));
    collector.collect(PriceSourceC {}, option::some(float::from_bps(3_6000)));
    collector.collect(PriceSourceM {}, option::some(float::from_bps(4_0000)));
    sui_agg.aggregate(collector);
    ts::return_shared(sui_agg);

    scenario.end();
}

#[test, expected_failure(abort_code = aggregator::ETotalWeightNotEnough)]
fun test_zero_total_weight() {
    let dev = @0xde1;
    let mut scenario = ts::begin(dev);
    let s = &mut scenario;
    listing::init_for_testing(s.ctx());

    let weight_threshold = 2;
    let outlier_tolerance_bps = 100;
    s.next_tx(dev);
    let mut cap = s.take_from_sender<ListingCap>();
    aggregator::create<SUI>(&mut cap, weight_threshold, outlier_tolerance_bps, s.ctx());
    s.return_to_sender(cap);

    s.next_tx(dev);
    let cap = s.take_from_sender<ListingCap>();
    let mut sui_agg = s.take_shared<PriceAggregator<SUI>>();
    sui_agg.set_rule_weight<SUI, PriceSourceA>(&cap, 1);
    sui_agg.set_rule_weight<SUI, PriceSourceA>(&cap, 2);
    sui_agg.set_rule_weight<SUI, PriceSourceB>(&cap, 1);
    sui_agg.set_rule_weight<SUI, PriceSourceC>(&cap, 1);
    sui_agg.set_rule_weight<SUI, PriceSourceM>(&cap, 10);
    sui_agg.set_rule_weight<SUI, PriceSourceM>(&cap, 0);
    s.return_to_sender(cap);
    ts::return_shared(sui_agg);

    let user = @0xcafe;
    s.next_tx(user);
    let sui_agg = s.take_shared<PriceAggregator<SUI>>();
    let mut collector = collector::new<SUI>();
    collector.collect(PriceSourceA {}, option::none());
    collector.collect(PriceSourceB {}, option::none());
    collector.collect(PriceSourceC {}, option::none());
    collector.collect(PriceSourceM {}, option::some(float::from_bps(4_0000)));
    sui_agg.aggregate(collector);
    ts::return_shared(sui_agg);

    scenario.end();
}

#[test, expected_failure(abort_code = aggregator::EInvalidWeight)]
fun test_total_invalid_weight() {
    let dev = @0xde1;
    let mut scenario = ts::begin(dev);
    let s = &mut scenario;
    listing::init_for_testing(s.ctx());

    let weight_threshold = 1;
    let outlier_tolerance_bps = 100;
    s.next_tx(dev);
    let mut cap = s.take_from_sender<ListingCap>();
    aggregator::create<SUI>(&mut cap, weight_threshold, outlier_tolerance_bps, s.ctx());
    s.return_to_sender(cap);

    s.next_tx(dev);
    let cap = s.take_from_sender<ListingCap>();
    let mut sui_agg = s.take_shared<PriceAggregator<SUI>>();
    sui_agg.set_rule_weight<SUI, PriceSourceM>(&cap, 0);
    s.return_to_sender(cap);
    ts::return_shared(sui_agg);

    scenario.end();
}

#[test, expected_failure(abort_code = aggregator::EInvalidThreshold)]
fun test_create_with_invalid_threshold() {
    let dev = @0xde1;
    let mut scenario = ts::begin(dev);
    let s = &mut scenario;
    listing::init_for_testing(s.ctx());

    s.next_tx(dev);
    let mut cap = s.take_from_sender<ListingCap>();
    aggregator::create<SUI>(&mut cap, 0, 100, s.ctx());
    s.return_to_sender(cap);

    scenario.end();
}

#[test, expected_failure(abort_code = aggregator::EInvalidThreshold)]
fun test_update_with_invalid_threshold() {
    let dev = @0xde1;
    let mut scenario = ts::begin(dev);
    let s = &mut scenario;
    listing::init_for_testing(s.ctx());

    s.next_tx(dev);
    let mut cap = s.take_from_sender<ListingCap>();
    aggregator::create<SUI>(&mut cap, 10, 100, s.ctx());
    s.return_to_sender(cap);

    s.next_tx(dev);
    let cap = s.take_from_sender<ListingCap>();
    let mut sui_agg = s.take_shared<PriceAggregator<SUI>>();
    sui_agg.set_weight_threshold(&cap, 0);
    s.return_to_sender(cap);
    ts::return_shared(sui_agg);

    scenario.end();
}
