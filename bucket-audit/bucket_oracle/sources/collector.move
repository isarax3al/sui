// Module for collecting price data from different rule types
module bucket_v2_oracle::collector;

use std::type_name::{get, TypeName};
use sui::vec_map::{Self, VecMap};
use bucket_v2_framework::float::{Float};

/// PriceCollector is a generic struct that collects prices for different rule types.
/// The phantom type parameter T allows the collector to be specialized for different contexts.
public struct PriceCollector<phantom T> has drop {
    // Maps a rule's TypeName to its collected Float price value.
    contents: VecMap<TypeName, Option<Float>>,
}

/// Creates a new, empty PriceCollector for a given context T.
public fun new<T>(): PriceCollector<T> {
    PriceCollector<T> {
        contents: vec_map::empty(), // Start with an empty VecMap
    }
}

// Collects a price for a rule type R into the collector.
// If a price for this rule type already exists, it is overwritten.
// - collector: the mutable PriceCollector to update
// - _witenss: a witness value of type R (not used, but enforces type tracking)
// - price: the Float price to record
public fun collect<T, R: drop>(
    collector: &mut PriceCollector<T>,
    _witenss: R,
    price: Option<Float>,
) {
    let rule_type = get<R>(); // Get the unique TypeName for R
    if (!collector.contents().contains(&rule_type)) {
        // If this rule type is not yet in the map, insert it
        collector.contents.insert(rule_type, price);
    } else {
        // If it already exists, update the price
        *collector.contents.get_mut(&rule_type) = price;
    };
}

/// Returns an immutable reference to the contents VecMap of the collector.
/// This allows inspection of all collected prices by rule type.
public fun contents<T>(
    collector: &PriceCollector<T>,
): &VecMap<TypeName, Option<Float>> {
    &collector.contents
}

/// Package fun to for aggregator module to remove outlier
public(package) fun remove<T>(
    collector: &mut PriceCollector<T>,
    rule_type: &TypeName,
) {
    if (collector.contents().contains(rule_type)) {
        collector.contents.remove(rule_type);
    }
}
