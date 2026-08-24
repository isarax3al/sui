/// Main module for BucketV2 USD (USDB) stablecoin logic
module bucket_v2_usd::usdb;

use std::type_name::{get, TypeName};
use std::string::{String};
use sui::coin::{Self, TreasuryCap, Coin};
use sui::balance::{Self, Balance};
use sui::vec_map::{Self, VecMap};
use sui::vec_set::{Self, VecSet};
use sui::url;
use sui::event;
use sui::dynamic_field::{Self as df};
use sui::dynamic_object_field::{Self as dof};
use bucket_v2_framework::account::{AccountRequest};
use bucket_v2_usd::admin::{AdminCap};
use bucket_v2_usd::limited_supply::{Self, LimitedSupply};
use bucket_v2_usd::treasury;

/// Errors

const EInvalidModule: u64 = 201;
fun err_invalid_module() { abort EInvalidModule }

const EInvalidModuleVersion: u64 = 202;
fun err_invalid_module_version() { abort EInvalidModuleVersion }

const ENotBeneficiary: u64 = 203;
fun err_not_beneficiary() { abort ENotBeneficiary }

const ECoinTypeNotFound: u64 = 204;
fun err_coin_type_not_found() { abort ECoinTypeNotFound }

/// Events

public struct Mint<phantom Module> has copy, drop {
    amount: u64, // Amount minted
    module_supply: u64, // Module-specific supply after mint
    total_supply: u64, // Total USDB supply after mint
}

public struct Burn<phantom Module> has copy, drop {
    amount: u64, // Amount burned
    module_supply: u64, // Module-specific supply after burn
    total_supply: u64, // Total USDB supply after burn
}

/// OTW
public struct USDB has drop {}

/// Key for accessing the TreasuryCap in dynamic object fields
public struct CapKey has store, copy, drop {}

public struct ModuleConfig has store {
    valid_versions: VecSet<u16>,
    limited_supply: LimitedSupply,
}

/// Main Treasury object holding supply maps, versions, and beneficiary
public struct Treasury has key {
    id: UID, // Unique object ID
    module_config_map: VecMap<TypeName, ModuleConfig>,
    beneficiary_address: address, // Address allowed to claim collected funds
}

/// Initializes the USDB coin and Treasury object
fun init(otw: USDB, ctx: &mut TxContext) {
    // Create the USDB coin and its metadata
    let (cap, metadata) = coin::create_currency(
        otw,
        decimal(),
        b"USDB",
        b"Bucket USD",
        b"USDB is a decentralized, overcollateralized stablecoin of bucketprotocol.io, pegged to 1 USD and backed by crypto assets via CDP and PSM mechanisms.",
        option::some(url::new_unsafe_from_bytes(
            b"https://www.bucketprotocol.io/icons/USDB.svg"),
        ),
        ctx,
    );
    transfer::public_share_object(metadata);
    let mut id = object::new(ctx);
    // Store the TreasuryCap in the object field
    dof::add(&mut id, cap_key(), cap);
    let treasury = Treasury {
        id,
        module_config_map: vec_map::empty(),
        beneficiary_address: ctx.sender(),
    };
    transfer::share_object(treasury);
}

/// =====================
/// Admin Functions
/// =====================

/// Set the beneficiary address for the Treasury
public fun set_beneficiary_address(
    treasury: &mut Treasury,
    _cap: &AdminCap,
    beneficiary_address: address,
) {
    treasury.beneficiary_address = beneficiary_address;
}

/// Set or update the supply limit for a module
public fun set_supply_limit<M: drop>(
    treasury: &mut Treasury,
    _cap: &AdminCap,
    supply_limit: u64,
) {
    let module_type = get<M>();
    if (treasury.module_config_map().contains(&module_type)) {
        treasury
            .module_config_map
            .get_mut(&module_type)
            .limited_supply
            .set_limit(supply_limit);
    } else {
        let limited_supply = limited_supply::new(supply_limit);
        treasury.module_config_map.insert(module_type, ModuleConfig {
            valid_versions: vec_set::empty(),
            limited_supply
        });
    };
}

/// Add a supported version for a module
public fun add_version<M: drop>(
    treasury: &mut Treasury,
    _cap: &AdminCap,
    version: u16,
) {
    let module_type = get<M>();
    if (treasury.module_config_map().contains(&module_type)) {
        treasury
            .module_config_map
            .get_mut(&module_type)
            .valid_versions
            .insert(version);
    } else {
        treasury
            .module_config_map
            .insert(
                module_type,
                ModuleConfig {
                    valid_versions: vec_set::singleton(version),
                    limited_supply: limited_supply::new(0),
                },
            );
    };
}

/// Remove a supported version for a module
public fun remove_version<M: drop>(
    treasury: &mut Treasury,
    _cap: &AdminCap,
    version: u16,
) {
    let module_type = get<M>();
    let cmap = treasury.module_config_map();
    if (
        cmap.contains(&module_type) &&
        cmap.get(&module_type).valid_versions().contains(&version)
    ) {
        treasury
            .module_config_map
            .get_mut(&module_type)
            .valid_versions
            .remove(&version);
    };
}

/// Remove a module and its supply/version records from the Treasury
public fun remove_module<M: drop>(
    treasury: &mut Treasury,
    _cap: &AdminCap,
) {
    let module_type = get<M>();
    if (treasury.module_config_map().contains(&module_type)) {
        let (_, config) = treasury.module_config_map.remove(&module_type);
        let ModuleConfig { valid_versions: _, limited_supply } = config;
        limited_supply.destroy();
    };
}

/// =====================
/// Public Functions
/// =====================

/// Mint USDB for a module, increasing its supply
public fun mint<M: drop>(
    treasury: &mut Treasury,
    _witness: M,
    version: u16,
    amount: u64,
    ctx: &mut TxContext,
): Coin<USDB> {
    treasury.assert_valid_module_version<M>(version);
    if (amount > 0) {
        let supply_mut = treasury.borrow_supply_mut<M>();
        let module_supply = supply_mut.increase(amount);
        let out = treasury.borrow_cap_mut().mint(amount, ctx);
        event::emit(Mint<M> {
            amount,
            module_supply,
            total_supply: treasury.total_supply(),
        });
        out
    } else {
        coin::zero(ctx)
    }
}

/// Burn USDB for a module, decreasing its supply
public fun burn<M: drop>(
    treasury: &mut Treasury,
    _witness: M,
    version: u16,
    coin: Coin<USDB>,
) {
    treasury.assert_valid_module_version<M>(version);
    let amount = coin.value();
    if (amount > 0) {
        let supply_mut = treasury.borrow_supply_mut<M>();
        let module_supply = supply_mut.decrease(amount);
        treasury.borrow_cap_mut().burn(coin);
        event::emit(Burn<M> {
            amount,
            module_supply,
            total_supply: treasury.total_supply(),
        });
    } else {
        coin.destroy_zero();
    }
}

/// Collect a balance of any coin type into the Treasury, associated with a module and memo
public fun collect<T, M: drop>(
    treasury: &mut Treasury,
    _witness: M,
    memo: String,
    balance: Balance<T>,
) {
    let amount = balance.value();
    if (amount > 0) {
        let treasury_id = &mut treasury.id;
        let coin_type = get<T>();
        // Ensure claimable map exists for this coin type
        if (!df::exists_with_type<TypeName, VecMap<TypeName, Balance<T>>>(treasury_id , coin_type)) {
            df::add(treasury_id, coin_type, vec_map::empty<TypeName, Balance<T>>());
        };
        let claimable_map = df::borrow_mut<TypeName, VecMap<TypeName, Balance<T>>>(treasury_id, coin_type);
        let module_type = get<M>();
        // Ensure claimable entry exists for this module
        if (!claimable_map.contains(&module_type)) {
            claimable_map.insert(module_type, balance::zero());
        };
        treasury::emit_collect_fee<T, M>(memo, amount);
        claimable_map.get_mut(&module_type).join(balance);
    } else {
        balance.destroy_zero();
    };
}

/// Claim collected coins for a module, only allowed by the beneficiary
public fun claim<T, M: drop>(
    treasury: &mut Treasury,
    account_req: &AccountRequest,
    ctx: &mut TxContext,
): Option<Coin<T>> {
    if (treasury.beneficiary_address() != account_req.address()) {
        err_not_beneficiary();
    };
    let treasury_id = &mut treasury.id;
    let coin_type = get<T>();
    // If no claimable map for this coin type, return none
    if (!df::exists_with_type<TypeName, VecMap<TypeName, Balance<T>>>(treasury_id , coin_type)) {
        return option::none()
    };
    let claimable_map = df::borrow_mut<TypeName, VecMap<TypeName, Balance<T>>>(treasury_id, coin_type);
    let module_type = get<M>();
    // If no claimable entry for this module, return none
    if (!claimable_map.contains(&module_type)) {
        return option::none()
    };
    // Remove and return the claimable balance as a Coin
    let (_, out) = claimable_map.remove(&module_type);
    let out = out.into_coin(ctx);
    if (out.value() > 0) {
        treasury::emit_claim_fee<T, M>(out.value());
    };
    option::some(out)
}

/// =====================
/// Getter Functions
/// =====================

/// Returns the decimal precision for USDB (6 decimals)
public fun decimal(): u8 { 6 }

/// Returns the total supply of USDB
public fun total_supply(treasury: &Treasury): u64 {
    treasury.borrow_cap().total_supply()
}

/// Returns the module supply map
public fun module_config_map(
    treasury: &Treasury,
): &VecMap<TypeName, ModuleConfig> {
    &treasury.module_config_map
}

/// Returns the limited supply for a given module
public fun limited_supply(config: &ModuleConfig): &LimitedSupply {
    &config.limited_supply
}

/// Returns the valid versions for a given module
public fun valid_versions(config: &ModuleConfig): &VecSet<u16> {
    &config.valid_versions
}

/// Returns the beneficiary address
public fun beneficiary_address(treasury: &Treasury): address {
    treasury.beneficiary_address
}

public fun is_claimable_map_exists_type<T>(
    treasury: &Treasury,
): bool {
    let coin_type = get<T>();
    df::exists_with_type<TypeName, VecMap<TypeName, Balance<T>>>(&treasury.id, coin_type)
}

/// Returns the claimable map for a given coin type, aborts if not found
public fun claimable_map<T>(
    treasury: &Treasury,
): &VecMap<TypeName, Balance<T>> {
    let coin_type = get<T>();
    if (!df::exists_with_type<TypeName, VecMap<TypeName, Balance<T>>>(&treasury.id, coin_type)) {
        err_coin_type_not_found();
    };
    df::borrow(&treasury.id, get<T>())
}

/// Asserts that a module and version are valid and supply is set, returns the module type
public fun assert_valid_module_version<M>(
    treasury: &Treasury,
    version: u16,
): TypeName {
    let module_type = get<M>();
    let cmap = treasury.module_config_map();
    if (!cmap.contains(&module_type)) {
        err_invalid_module();
    };
    if (!cmap.get(&module_type).valid_versions().contains(&version)) {
        err_invalid_module_version();
    };
    module_type
}

/// =====================
/// Internal Functions
/// =====================

/// Returns a new CapKey
fun cap_key(): CapKey { CapKey {} }

/// Borrows the mutable TreasuryCap from the Treasury object
fun borrow_cap_mut(treasury: &mut Treasury): &mut TreasuryCap<USDB> {
    dof::borrow_mut(&mut treasury.id, cap_key())
}

/// Borrows the immutable TreasuryCap from the Treasury object
fun borrow_cap(treasury: &Treasury): &TreasuryCap<USDB> {
    dof::borrow(&treasury.id, cap_key())
}

/// Borrows the mutable LimitedSupply for a module, asserting validity
fun borrow_supply_mut<M>(
    treasury: &mut Treasury,
): &mut LimitedSupply {
    &mut treasury.module_config_map.get_mut(&get<M>()).limited_supply
}

/// =====================
/// Test-only Functions
/// =====================

/// Initializes USDB and Treasury for testing purposes
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(USDB {}, ctx);
}
