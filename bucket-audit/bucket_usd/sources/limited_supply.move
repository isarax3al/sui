/// Module for managing a limited supply of tokens or assets.
/// Provides functionality to create, increase, decrease, and destroy a supply with an upper limit.
module bucket_v2_usd::limited_supply;

const EDestroyNonEmptySupply: u64 = 101;
fun err_destroy_non_empty_supply() { abort EDestroyNonEmptySupply }

const ESupplyExceedLimit: u64 = 102;
fun err_exceed_limit() { abort ESupplyExceedLimit }

const ESupplyNotEnough: u64 = 103;
fun err_supply_not_enough() { abort ESupplyNotEnough }

/// Struct representing a limited supply with a maximum limit and current supply.
public struct LimitedSupply has store {
    /// The maximum allowed supply.
    limit: u64,
    /// The current supply.
    supply: u64,
}

/// Creates a new LimitedSupply with the given limit and zero initial supply.
public fun new(limit: u64): LimitedSupply {
    LimitedSupply {
        limit, supply: 0,
    }
}

/// Destroys the LimitedSupply. Aborts if the supply is not zero.
public fun destroy(self: LimitedSupply) {
    let LimitedSupply { limit: _, supply } = self;
    if (supply > 0) {
        err_destroy_non_empty_supply();
    };
}

/// Increases the supply by the given amount. Aborts if the new supply exceeds the limit.
/// Returns the new supply.
public fun increase(self: &mut LimitedSupply, amount: u64): u64 {
    self.supply = self.supply() + amount;
    if (self.supply() > self.limit()) {
        err_exceed_limit();
    };
    self.supply()
}

/// Decreases the supply by the given amount. Aborts if the supply is not enough.
/// Returns the new supply.
public fun decrease(self: &mut LimitedSupply, amount: u64): u64 {
    if (self.supply() < amount) {
        err_supply_not_enough();
    };
    self.supply = self.supply() - amount;
    self.supply()
}

/// Sets a new limit for the supply.
public fun set_limit(self: &mut LimitedSupply, limit: u64) {
    self.limit = limit;
}

/// Returns the limit of the supply.
public fun limit(self: &LimitedSupply): u64 {
    self.limit
}

/// Returns the current supply.
public fun supply(self: &LimitedSupply): u64 {
    self.supply
}

public fun increasable_amount(self: &LimitedSupply): u64 {
    if (self.limit() > self.supply()) {
        self.limit() - self.supply()
    } else {
        0
    }
}

/// Returns true if the supply can be increased by the given amount without exceeding the limit.
public fun is_increasable(self: &LimitedSupply, amount: u64): bool {
    amount <= self.increasable_amount()
}

/// Destroys the LimitedSupply for testing purposes, ignoring the supply value.
#[test_only]
public fun destroy_for_testing(self: LimitedSupply) {
    let LimitedSupply { limit: _, supply: _ } = self;
}

/// Unit test: checks that decreasing supply below zero aborts with the correct error code.
#[test, expected_failure(abort_code = ESupplyNotEnough)]
fun test_supply_not_enough() {
    let mut supply = new(100);
    supply.increase(99);
    supply.decrease(100);
    supply.destroy_for_testing();
}
