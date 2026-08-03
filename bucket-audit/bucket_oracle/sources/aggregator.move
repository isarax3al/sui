/// Module for aggregating prices from multiple sources with weighted rules and threshold logic.
module bucket_v2_oracle::aggregator;

use std::ascii::{String};
use std::type_name::{get, TypeName};
use sui::vec_map::{Self, VecMap};
use sui::event;
use bucket_v2_framework::float::{Self, Float};
use bucket_v2_oracle::listing::{ListingCap};
use bucket_v2_oracle::collector::{PriceCollector};
use bucket_v2_oracle::result::{Self, PriceResult};

/// Errors

const EMissingPriceSource: u64 = 201;
fun err_missing_price_source() { abort EMissingPriceSource }

const EInvalidWeight: u64 = 202;
fun err_invalid_weight() { abort EInvalidWeight }

const EInvalidThreshold: u64 = 203;
fun err_invalid_threshold() { abort EInvalidThreshold }

const ETotalWeightNotEnough: u64 = 204;
fun err_total_weight_not_enough() { abort ETotalWeightNotEnough }

/// Events

/// Emitted when a new PriceAggregator is created
public struct NewPriceAggregator has copy, drop {
    aggregator_id: ID,
    coin_type: String,
    weight_threshold: u64,
    outlier_tolerance_bps: u64,
}

/// Emitted when a rule's weight is updated
public struct WeightUpdated<phantom T> has copy, drop {
    aggregator_id: ID,
    rule_type: String,
    weight: u8,
}

/// Emitted when the weight threshold is updated
public struct ThresholdUpdated<phantom T> has copy, drop {
    aggregator_id: ID,
    weight_threshold: u64,
}

/// Emitted when the outlier tolerance is updated
public struct OutlierToleranceUpdated<phantom T> has copy, drop {
    aggregator_id: ID,
    outlier_tolerance_bps: u64,
}

/// Emitted when a price is aggregated
public struct PriceAggregated<phantom T> has copy, drop {
    aggregator_id: ID,
    sources: vector<String>,
    prices: vector<u128>,
    weights: vector<u8>,
    current_threshold: u64,
    result: u128,
}

/// Object

/// Stores weights for each rule and the threshold for aggregation
public struct PriceAggregator<phantom T> has key, store {
    id: UID,
    weights: VecMap<TypeName, u8>, // Mapping from rule type to weight
    weight_threshold: u64,         // Minimum total weight required to aggregate
    outlier_tolerance: Float,      // Maximum allowed deviation from the median price
}

/// Admin Funs

/// Create a new PriceAggregator object for a given coin type
public fun new<T>(
    cap: &mut ListingCap,
    weight_threshold: u64,
    outlier_tolerance_bps: u64,
    ctx: &mut TxContext,
): PriceAggregator<T> {
    if (weight_threshold == 0) {
        err_invalid_threshold();
    };
    let id = object::new(ctx);
    let aggregator_id = id.to_inner();
    let agg = PriceAggregator<T> {
        id,
        weights: vec_map::empty(),
        weight_threshold,
        outlier_tolerance: float::from_bps(outlier_tolerance_bps),
    };
    let coin_type = cap.register<T>(aggregator_id).into_string();
    event::emit(NewPriceAggregator {
        aggregator_id,
        coin_type,
        weight_threshold,
        outlier_tolerance_bps,
    });
    agg
}

/// Entry function to create and share a new PriceAggregator object
#[allow(lint(share_owned))]
entry fun create<T>(
    cap: &mut ListingCap,
    weight_threshold: u64,
    outlier_tolerance_bps: u64,
    ctx: &mut TxContext,
) {
    let agg = new<T>(cap, weight_threshold, outlier_tolerance_bps, ctx);
    transfer::share_object(agg);
}

/// Set or update the weight for a specific rule type
public fun set_rule_weight<T, R>(
    self: &mut PriceAggregator<T>,
    _cap: &ListingCap,
    new_weight: u8,
) {
    let rule_type = get<R>();
    let weights = &mut self.weights;
    if (weights.contains(&rule_type)) {
        if (new_weight > 0) {
            *weights.get_mut(&rule_type) = new_weight;
        } else {
            weights.remove(&rule_type);
        };
    } else {
        if (new_weight > 0) {
            weights.insert(rule_type, new_weight);
        } else {
            err_invalid_weight();
        };
    };
    event::emit(WeightUpdated<T> {
        aggregator_id: object::id(self),
        rule_type: rule_type.into_string(),
        weight: new_weight,
    });
}

/// Set the minimum total weight required for aggregation
public fun set_weight_threshold<T>(
    self: &mut PriceAggregator<T>,
    _cap: &ListingCap,
    weight_threshold: u64,
) {
    if (weight_threshold == 0) {
        err_invalid_threshold();
    };
    self.weight_threshold = weight_threshold;
    event::emit(ThresholdUpdated<T> {
        aggregator_id: object::id(self),
        weight_threshold,
    });
}

public fun set_outlier_tolerance<T>(
    self: &mut PriceAggregator<T>,
    _cap: &ListingCap,
    outlier_tolerance_bps: u64,
) {
    self.outlier_tolerance = float::from_bps(outlier_tolerance_bps);
    event::emit(OutlierToleranceUpdated<T> {
        aggregator_id: object::id(self),
        outlier_tolerance_bps,
    });
}

/// Public Funs

/// Aggregate prices from the collector using the weights and threshold
public fun aggregate<T>(
    self: &PriceAggregator<T>,
    mut collector: PriceCollector<T>,
): PriceResult<T> {
    // Get all rule types from the collector
    self.remove_outliers(&mut collector);
    let rules = collector.contents().keys();

    // Prepare vectors for event emission
    let mut sources = vector[];
    let mut prices = vector[];
    let mut weights = vector[];
    // Calculate the weighted sum of prices
    let price_weighted_sum = rules.fold!(float::zero(), |sum, rule| {
        let price_opt = collector.contents().get(&rule);
        let weight = *self.weights().get(&rule);
        if (price_opt.is_some()) {
            let price = *price_opt.borrow();
            sources.push_back(rule);
            prices.push_back(price.to_scaled_val());
            weights.push_back(weight);
            sum.add(price.mul_u64(weight as u64))
        } else {
            sum
        }
    });
    let total_weight_of_collector = (weights.fold!(0, |sum, w| sum + w) as u64);
    if (total_weight_of_collector < self.weight_threshold()) {
        err_total_weight_not_enough();
    };
    // Compute the aggregated price
    let aggregated_price = price_weighted_sum.div_u64(total_weight_of_collector);
    // Emit event with aggregation details
    event::emit(PriceAggregated<T> {
        aggregator_id: object::id(self),
        sources: sources.map!(|s| s.into_string()),
        prices,
        weights,
        current_threshold: self.weight_threshold,
        result: aggregated_price.to_scaled_val(),
    });
    // Return the result as a PriceResult
    result::new<T>(aggregated_price)
}

/// Getter Functions

/// Get the weights map
public fun weights<T>(self: &PriceAggregator<T>): &VecMap<TypeName, u8> {
    &self.weights
}

/// Get the current weight threshold
public fun weight_threshold<T>(self: &PriceAggregator<T>): u64 {
    self.weight_threshold
}

/// Get the current weight threshold
public fun outlier_tolerance<T>(self: &PriceAggregator<T>): Float {
    self.outlier_tolerance
}

/// Internal fun to remove outlier
fun remove_outliers<T>(
    self: &PriceAggregator<T>,
    collector: &mut PriceCollector<T>,
) {
    // Check if every source is collected
    let all_sources_collected = self.weights.keys().all!(
        |rule| collector.contents().contains(rule)
    );
    if (!all_sources_collected) {
        err_missing_price_source();
    };

    let removable_rules = collector.contents().keys().filter!(
        |rule| collector.contents().get(rule).is_none()
    );
    removable_rules.do_ref!(|rule| { collector.remove(rule) });
    let rules = collector.contents().keys();
    let total_weight = rules.fold!(0, |sum, rule| {
        let weight = self.weights().try_get(&rule).destroy_or!(0);
        sum + (weight as u64)
    });
    if (total_weight == 0) {
        err_total_weight_not_enough();
    };

    let weighted_avg = rules.fold!(float::zero(), |sum, rule| {
        let price_opt = collector.contents().get(&rule);
        let weight = self.weights().try_get(&rule).destroy_or!(0);
        if (price_opt.is_some()) {
            let price = *price_opt.borrow();
            sum.add(price.mul_u64(weight as u64))
        } else {
            sum
        }
    }).div_u64(total_weight);

    let removable_rules = collector.contents().keys()
        .filter!(|rule|
            !self.weights().contains(rule) || {
                let price = *collector.contents().get(rule).borrow();
                weighted_avg.diff(price).div(weighted_avg).gt(self.outlier_tolerance())
            }
        );
    removable_rules.do_ref!(|rule| { collector.remove(rule) });
}
