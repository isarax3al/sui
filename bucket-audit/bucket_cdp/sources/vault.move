/// Vault module for managing collateralized debt positions (CDPs) in the BucketV2 protocol.
/// Handles vault creation, position management, interest accrual, liquidation, and admin controls.
module bucket_v2_cdp::vault;

use std::type_name::{get, TypeName};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::clock::{Clock};
use sui::vec_set::{Self, VecSet};
use bucket_v2_framework::float::{Self, Float};
use bucket_v2_framework::double::{Self, Double};
use bucket_v2_framework::linked_table::{Self, LinkedTable};
use bucket_v2_framework::account::{AccountRequest};
use bucket_v2_framework::sheet::{Self, Sheet};
use bucket_v2_usd::limited_supply::{Self, LimitedSupply};
use bucket_v2_usd::admin::{AdminCap};
use bucket_v2_usd::usdb::{Self, USDB, Treasury};
use bucket_v2_oracle::result::{PriceResult};
use bucket_v2_cdp::version::{Self, package_version};
use bucket_v2_cdp::witness::{witness, BucketV2CDP};
use bucket_v2_cdp::events;
use bucket_v2_cdp::request::{Self, UpdateRequest};
use bucket_v2_cdp::response::{Self, UpdateResponse};
use bucket_v2_cdp::memo;
use bucket_v2_cdp::acl::{Self, Acl};

/// Errors

const EMissingRequestWitness: u64 = 401;
fun err_missing_request_witness() { abort EMissingRequestWitness }

const EMissingResponseWitness: u64 = 402;
fun err_missing_response_witness() { abort EMissingResponseWitness }

const EOaclePriceIsRequired: u64 = 403;
fun err_oracle_price_is_required() { abort EOaclePriceIsRequired }

const EPositionIsNotHealthy: u64 = 404;
fun err_position_is_not_healthy() { abort EPositionIsNotHealthy }

const EPositionIsHealthy: u64 = 405;
fun err_position_is_healthy() { abort EPositionIsHealthy }

const EInvalidLiquidation: u64 = 406;
fun err_invalid_liquidation() { abort EInvalidLiquidation }

const EDebtorNotFound: u64 = 407;
fun err_debtor_not_found() { abort EDebtorNotFound }

const ERepayTooMuch: u64 = 408;
fun err_repay_too_much() { abort ERepayTooMuch }

const EWithdrawTooMuch: u64 = 409;
fun err_withdraw_too_much() { abort EWithdrawTooMuch }

const EWrongVaultId: u64 = 410;
fun err_wrong_vault_id() { abort EWrongVaultId }

const EInvalidVaultSettings: u64 = 411;
fun err_invalid_vault_settings() { abort EInvalidVaultSettings }

const EAgainstSecurityLevel: u64 = 412;
fun err_against_security_level() { abort EAgainstSecurityLevel }

const ENotManager: u64 = 413;
fun err_not_manager() { abort ENotManager }

const EPositionIsLocked: u64 = 414;
fun err_position_is_locked() { abort EPositionIsLocked }

const EInvalidMinCollateralRatio: u64 = 415;
fun err_invalid_min_collateral_ratio() { abort EInvalidMinCollateralRatio }

const EInvalidSecurityLevel: u64 = 416;
fun err_invalid_security_level() { abort EInvalidSecurityLevel }

/// Constants
const MIN_COLLATERAL_RATIO_PERCENTAGE: u8 = 110;
public fun min_collateral_ratio_percentage(): u8{
    MIN_COLLATERAL_RATIO_PERCENTAGE
}

/// Struct

/// Struct representing a user's position in the vault
/// - interest_unit: personal interest unit
/// - coll_amount: collateral amount
/// - debt_amount: debt amount (USDB)
public struct Position has store, copy, drop {
    coll_amount: u64,
    debt_amount: u64,
    interest_unit: Double,
}

/// Object

/// Main Vault object holding configuration, state, and positions
/// - T: collateral type
public struct Vault<phantom T> has key, store {
    id: UID, // Unique object ID
    /// No security checking when value equals 0; security == 1 is the strictest level.
    /// Any level greater than or equal to the current non-zero security level will be aborted.
    security_level: Option<u8>,
    access_control: Acl,
    // invariant config
    decimal: u8, // Collateral decimals
    interest_rate: Double, // Annual interest rate
    interest_unit: Double, // Interest unit of vault
    timestamp: u64, // Latest update timestamp (ms)
    total_pending_interest_amount: u64, // Pending interest amount (USDB)
    // variant config
    limited_supply: LimitedSupply, // USDB supply limit
    total_coll_amount: u64,
    total_debt_amount: u64, // Sum of all debtor's debt amount (USDB)
    min_collateral_ratio: Float, // Minimum collateral ratio
    liquidation_rule: TypeName, // Liquidation rule type
    // checklists
    request_checklist: vector<TypeName>, // Required request witnesses
    response_checklist: vector<TypeName>, // Required response witnesses
    // states
    position_table: LinkedTable<address, Position>, // User positions
    balance: Balance<T>, // Vault's collateral balance
    position_locker: VecSet<address>, // lock the position after update request to prevent reentrance
    sheet: Sheet<T, BucketV2CDP>,
}

/// Admin Funs

/// Create a new vault with specified parameters. Only callable by admin.
public fun new<T, LR: drop>(
    treasury: &Treasury,
    _cap: &AdminCap,
    // invariant config
    decimal: u8,
    interest_rate: Double,
    // variant config
    supply_limit: u64,
    min_collateral_ratio: Float,
    ctx: &mut TxContext,
): Vault<T> {
    version::assert_valid_package(treasury);
    let limited_supply = limited_supply::new(supply_limit);
    let id = object::new(ctx);
    let vault_id = id.to_inner();
    if (interest_rate.gt(double::from(1))) {
        err_invalid_vault_settings();
    };
    if (min_collateral_ratio.lte(float::from(1))) {
        err_invalid_vault_settings();
    };
    events::emit_vault_created<T>(
        vault_id,
        interest_rate,
        supply_limit,
        min_collateral_ratio,
    );
    Vault<T> {
        id,
        // open to all feature
        security_level: option::none(),
        // ACL
        access_control: acl::new(),
        // invariant config
        decimal,
        interest_rate,
        interest_unit: double::zero(),
        timestamp: 0,
        total_pending_interest_amount: 0,
        // variant config
        limited_supply,
        total_coll_amount: 0,
        total_debt_amount: 0,
        min_collateral_ratio,
        liquidation_rule: get<LR>(),
        // checklists
        request_checklist: vector[],
        response_checklist: vector[],
        // states
        position_table: linked_table::new(ctx),
        balance: balance::zero(),
        position_locker: vec_set::empty(),
        sheet: sheet::new(witness()),
    }
}

/// Entry point for creating a new vault object and sharing it on chain
#[allow(lint(share_owned))]
entry fun create<T, LR: drop>(
    treasury: &Treasury,
    cap: &AdminCap,
    // invariant config
    decimal: u8,
    interest_rate_bps: u64,
    // variant config
    supply_limit: u64,
    min_collateral_ratio_bps: u64,
    ctx: &mut TxContext,
) {
    let min_collateral_ratio = float::from_bps(min_collateral_ratio_bps);
    if(min_collateral_ratio.lt(float::from_percent(min_collateral_ratio_percentage()))) err_invalid_min_collateral_ratio();

    let vault = new<T, LR>(
        treasury,
        cap,
        // invariant config
        decimal,
        double::from_bps(interest_rate_bps),
        // variant config
        supply_limit,
        min_collateral_ratio,
        ctx,
    );
    transfer::share_object(vault);
}

public fun set_supply_limit<T>(
    vault: &mut Vault<T>,
    _cap: &AdminCap,
    limit: u64,
) {
    events::emit_supply_limit_updated<T>(
        object::id(vault),
        vault.limited_supply().limit(),
        limit,
    );
    vault.limited_supply.set_limit(limit);
}

public fun set_interest_rate<T>(
    vault: &mut Vault<T>,
    treasury: &mut Treasury,
    _cap: &AdminCap,
    clock: &Clock,
    interest_rate_bps: u64,
    ctx: &mut TxContext,
) {
    version::assert_valid_package(treasury);
    vault.collect_interest(treasury, clock, ctx);
    vault.interest_rate = double::from_bps(interest_rate_bps);

    events::emit_interest_rate_updated<T>(object::id(vault), interest_rate_bps);
}

public fun set_liquidation_rule<T, LR: drop>(
    vault: &mut Vault<T>,
    _cap: &AdminCap,
) {
    let new_rule = get<LR>();
    events::emit_liquidation_rule_updated<T>(
        object::id(vault),
        vault.liquidation_rule(),
        new_rule,
    );
    vault.liquidation_rule = new_rule;
}

public fun add_request_check<T, W: drop>(
    vault: &mut Vault<T>,
    _cap: &AdminCap,
) {
    let witness_type = get<W>();
    if (!vault.request_checklist().contains(&witness_type)) {
        vault.request_checklist.push_back(witness_type);
    };
}

public fun remove_request_check<T, W: drop>(
    vault: &mut Vault<T>,
    _cap: &AdminCap,
) {
    let witness_type = get<W>();
    let idx_opt = vault.request_checklist().find_index!(|w| w == witness_type);
    idx_opt.do!(|idx| vault.request_checklist.swap_remove(idx));
}

public fun add_response_check<T, W: drop>(
    vault: &mut Vault<T>,
    _cap: &AdminCap,
) {
    let witness_type = get<W>();
    if (!vault.response_checklist().contains(&witness_type)) {
        vault.response_checklist.push_back(witness_type);
    };
}

public fun remove_response_check<T, W: drop>(
    vault: &mut Vault<T>,
    _cap: &AdminCap,
) {
    let witness_type = get<W>();
    let idx_opt = vault.response_checklist().find_index!(|w| w == witness_type);
    idx_opt.do!(|idx| vault.response_checklist.swap_remove(idx));
}

public fun set_manager_role<T>(
    vault: &mut Vault<T>,
    _cap: &AdminCap,
    manager: address,
    level: u8
) {
    vault.access_control.set_role(manager, level);
}

public fun remove_manager_role<T>(
    vault: &mut Vault<T>,
    _cap: &AdminCap,
    manager: address,
) {
    vault.access_control.remove_role(manager);
}

public fun set_security_by_admin<T>(
    vault: &mut Vault<T>,
    _cap: &AdminCap,
    level: Option<u8>,
    ctx: &TxContext
) {
    if(level.is_some() && *level.borrow() == 0) err_invalid_security_level();

    vault.security_level = level;

    events::emit_set_security_level<T>(object::id(vault), ctx.sender(), level);
}

public fun set_security_by_manager<T>(
    vault: &mut Vault<T>,
    level: u8,
    ctx: &TxContext
) {
    let sender = ctx.sender();
    if(!vault.access_control.exists_role(sender)) err_not_manager();
    let manger_level = vault.access_control.role_level(sender);

    if(level == 0 || level < manger_level) err_invalid_security_level();

    vault.security_level = option::some(level);

    events::emit_set_security_level<T>(object::id(vault), ctx.sender(), option::some(level));
}

/// Public Funs

/// Update a user's position in the vault (deposit, withdraw, borrow, repay)
/// Handles interest accrual, collateralization checks, and emits events.
public fun update_position<T>(
    vault: &mut Vault<T>,
    treasury: &mut Treasury,
    clock: &Clock,
    coll_price_opt: &Option<PriceResult<T>>,
    request: UpdateRequest<T>,
    ctx: &mut TxContext,
): (Coin<T>, Coin<USDB>, UpdateResponse<T>) {
    version::assert_valid_package(treasury);
    let debtor = request.account();

    // check security by actions if the update request isn't from liquidate action
    if(request.memo() != memo::liquidate()){
        if(request.deposit_amount() > 0) {
            vault.check_security_level(1);
        };
        if(request.borrow_amount() > 0) {
            vault.check_security_level(2);
        };
        if(request.withdraw_amount() > 0) {
            vault.check_security_level(2);
        };
        if(request.repay_amount() > 0) {
            vault.check_security_level(2);
        };
    };

    let pos_table = &mut vault.position_table;
    let (
        mut position,
        interest_amount,
        next_debtor,
    ) = if (pos_table.contains(debtor)) {
        let next_debtor = *pos_table.next(debtor);
        let mut position = pos_table.remove(debtor);
        let interest_amount = vault.accrue_interest(&mut position, treasury, clock, ctx);
        (position, interest_amount, next_debtor)
    } else {
        vault.collect_interest(treasury, clock, ctx);
        let position = Position {
            coll_amount: 0,
            debt_amount: 0,
            interest_unit: vault.current_vault_interest_unit(clock),
        };
        (position, 0, option::none())
    };

    // Apply requested changes to position
    position.coll_amount = position.coll_amount + request.deposit_amount();
    position.debt_amount = position.debt_amount + request.borrow_amount();
    if (position.debt_amount < request.repay_amount()) {
        err_repay_too_much();
    };
    position.debt_amount = position.debt_amount - request.repay_amount();
    if (position.coll_amount < request.withdraw_amount()) {
        err_withdraw_too_much();
    };
    position.coll_amount = position.coll_amount - request.withdraw_amount();
    vault.total_debt_amount = vault.total_debt_amount + request.borrow_amount() - request.repay_amount();

    // If position is closed, don't reinsert; else update table
    let (coll_amount, debt_amount) = if (position.coll_amount == 0 && position.debt_amount == 0) {
        let Position { coll_amount, debt_amount, interest_unit: _ } = position;
        (coll_amount, debt_amount)
    } else {
        vault.position_table.insert_front(next_debtor, debtor, position);
        vault.get_position_data(debtor, clock)
    };

    // Unpack request and validate
    let (
        vault_id,
        account,
        deposit,
        borrow_amount,
        mut repayment,
        withdraw_amount,
        witnesses,
        memo,
    ) = request.destroy();
    if (vault_id != vault.id()) {
        err_wrong_vault_id();
    };
    if (!vault.request_checklist().all!(|rule| witnesses.contains(rule))) {
        err_missing_request_witness();
    };

    // Determine if collateral ratio check is required (for borrow/withdraw)
    let cr_check_required =
        memo == memo::manage() && (
            borrow_amount > 0 ||
            (withdraw_amount > 0 && debt_amount > 0)
        );

    if (cr_check_required) {
        if (coll_price_opt.is_some()) {
            if (!vault.position_is_healthy(debtor, clock, coll_price_opt.borrow())) {
                err_position_is_not_healthy();
            };
        } else {
            err_oracle_price_is_required();
        };
    };

    // Emit event for position update
    events::emit_position_updated<T>(
        object::id(vault),
        account,
        deposit.value(),
        borrow_amount,
        repayment.value(),
        withdraw_amount,
        interest_amount,
        coll_amount,
        debt_amount,
        memo,
    );

    // Update vault's collateral balance
    vault.total_coll_amount = vault.total_coll_amount + deposit.value() - withdraw_amount;
    vault.balance.join(deposit.into_balance());
    let coll_out = coin::take(&mut vault.balance, withdraw_amount, ctx);

    // Mint/burn USDB as needed, handle interest
    let usdb_out = if (borrow_amount > repayment.value()) {
        let diff = borrow_amount - repayment.value();
        let mut usdb_out = vault.mint_usdb(treasury, diff, ctx);
        usdb_out.join(repayment);
        usdb_out
    } else {
        let usdb_out = repayment.split(borrow_amount, ctx);
        if (repayment.value() > 0) {
            let claimable_interest_amount = repayment.value().min(
                vault.total_pending_interest_amount
            );
            if (claimable_interest_amount > 0) {
                vault.total_pending_interest_amount = vault.total_pending_interest_amount - claimable_interest_amount;
                let claimabl_interest = repayment.balance_mut().split(claimable_interest_amount);
                treasury.collect(witness(), memo::interest(), claimabl_interest);
            };
            vault.burn_usdb(treasury, repayment);
        } else {
            repayment.destroy_zero();
        };
        usdb_out
    };

    let response = response::new<T>(
        vault.id(), debtor, coll_amount, debt_amount, interest_amount);
    (coll_out, usdb_out, response)
}

/// Destroy a response object, checking required witnesses (for post-processing)
public fun destroy_response<T>(
    vault: &mut Vault<T>,
    treasury: &Treasury,
    response: UpdateResponse<T>,
) {
    version::assert_valid_package(treasury);
    vault.position_locker.remove(&response.account());
    let (vault_id, _account, _coll_amount, _debt_amount, _interest_amount, witnesses) = response.destroy();
    if (vault_id != vault.id()) {
        err_wrong_vault_id();
    };
    if (!vault.response_checklist().all!(|rule| witnesses.contains(rule))) {
        err_missing_response_witness();
    };
}

/// Creates a debtor request (user borrows or repays, can deposit/withdraw)
public fun debtor_request<T>(
    vault: &mut Vault<T>,
    account_req: &AccountRequest,
    treasury: &Treasury,
    deposit: Coin<T>,
    borrow_amount: u64,
    repayment: Coin<USDB>,
    withdraw_amount: u64,
): UpdateRequest<T> {
    version::assert_valid_package(treasury);
    let debtor = account_req.address();
    vault.assert_position_is_not_locked(debtor);
    vault.position_locker.insert(debtor);

    request::new(
        vault.id(), debtor, deposit, borrow_amount, repayment, withdraw_amount, memo::manage(),
    )
}

/// Creates a donor request (third party repays on behalf of a debtor, can deposit)
public fun donor_request<T>(
    vault: &mut Vault<T>,
    treasury: &Treasury,
    debtor: address,
    deposit: Coin<T>,
    repayment: Coin<USDB>,
): UpdateRequest<T> {
    version::assert_valid_package(treasury);
    vault.assert_position_is_not_locked(debtor);
    vault.position_locker.insert(debtor);

    request::new(
        vault.id(), debtor, deposit, 0, repayment, 0, memo::donate(),
    )
}

/// Liquidate an unhealthy position, returning a request to update the position
public fun liquidate<T, LR: drop>(
    vault: &mut Vault<T>,
    treasury: &Treasury,
    clock: &Clock,
    coll_price: &PriceResult<T>,
    debtor: address,
    repayment: Coin<USDB>,
    _liquidation_rule: LR,
    ctx: &mut TxContext,
): UpdateRequest<T> {
    version::assert_valid_package(treasury);
    vault.assert_position_is_not_locked(debtor);
    vault.position_locker.insert(debtor);
    if (vault.liquidation_rule != get<LR>()) {
        err_invalid_liquidation();
    };
    vault.check_security_level(1);
    if (vault.position_is_healthy(debtor, clock, coll_price)) {
        err_position_is_healthy();
    };
    let (coll_amount, debt_amount) = vault.get_position_data(debtor, clock);
    if (repayment.value() > debt_amount) {
       err_invalid_liquidation();
    };
    // Calculate proportional collateral to withdraw for the repaid debt
    let mut withdraw_amount =
        double::from(repayment.value())
        .mul_u64(coll_amount)
        .div_u64(debt_amount)
        .ceil();
    if (withdraw_amount > coll_amount) {
        withdraw_amount = coll_amount;
    };

    request::new(
        vault.id(), debtor, coin::zero(ctx), 0, repayment, withdraw_amount, memo::liquidate(),
    )
}

public fun collect_interest<T>(
    vault: &mut Vault<T>,
    treasury: &mut Treasury,
    clock: &Clock,
    ctx: &mut TxContext,
): Double {
    let current_interest_unit = vault.current_vault_interest_unit(clock);
    let unit_diff = current_interest_unit.sub(vault.interest_unit);
    let total_interest_amount = unit_diff.mul_u64(vault.total_debt_amount).ceil();
    if (total_interest_amount > 0) {
        let mintable_amount = total_interest_amount.min(vault.limited_supply().increasable_amount());
        let pending_amount = total_interest_amount - mintable_amount;
        if (mintable_amount > 0) {
            let interest = vault.mint_usdb(treasury, mintable_amount, ctx);
            treasury.collect(witness(), memo::interest(), interest.into_balance());
        };
        if (pending_amount > 0) {
            vault.total_pending_interest_amount = vault.total_pending_interest_amount + pending_amount;
        };
        vault.total_debt_amount = vault.total_debt_amount + total_interest_amount;
    };
    vault.interest_unit = current_interest_unit;
    vault.timestamp = clock.timestamp_ms();
    current_interest_unit
}

/// Getter Funs

/// Get vault's collateral decimal places
public fun decimal<T>(vault: &Vault<T>): u8 {
    vault.decimal
}

/// Get vault's interest rate
public fun interest_rate<T>(vault: &Vault<T>): Double {
    vault.interest_rate
}

/// Get reference to vault's limited supply object
public fun limited_supply<T>(vault: &Vault<T>): &LimitedSupply {
    &vault.limited_supply
}

/// Get vault's minimum collateral ratio
public fun min_collateral_ratio<T>(vault: &Vault<T>): Float {
    vault.min_collateral_ratio
}

/// Get vault's liquidation rule type
public fun liquidation_rule<T>(vault: &Vault<T>): TypeName {
    vault.liquidation_rule
}

/// Get reference to request witness checklist
public fun request_checklist<T>(vault: &Vault<T>): &vector<TypeName> {
    &vault.request_checklist
}

/// Get reference to response witness checklist
public fun response_checklist<T>(vault: &Vault<T>): &vector<TypeName> {
    &vault.response_checklist
}

/// Get reference to the position table
public fun position_table<T>(vault: &Vault<T>): &LinkedTable<address, Position> {
    &vault.position_table
}

/// Check if a position exists for a given debtor
public fun position_exists<T>(vault: &Vault<T>, debtor: address): bool {
    vault.position_table().contains(debtor)
}

public fun position_is_healthy<T>(
    vault: &Vault<T>,
    debtor: address,
    clock: &Clock,
    coll_price: &PriceResult<T>,
): bool {
    let (coll_amount, debt_amount) = vault.get_position_data(debtor, clock);
    if (debt_amount > 0) {
        let ten = 10u64;
        let coll_norm = ten.pow(vault.decimal());
        let usdb_norm = ten.pow(usdb::decimal());
        let coll_f = float::from_fraction(coll_amount, coll_norm);
        let debt_f = float::from_fraction(debt_amount, usdb_norm);
        let coll_price = coll_price.aggregated_price();
        let icr = coll_f.mul(coll_price).div(debt_f);
        icr.gte(vault.min_collateral_ratio)
    } else {
        true
    }
}

/// Get up-to-date collateral and debt for a debtor (including accrued interest)
public fun get_position_data<T>(vault: &Vault<T>, debtor: address, clock: &Clock): (u64, u64) {
    if (!vault.position_table.contains(debtor)) {
        err_debtor_not_found();
    };
    let current_vault_interest_unit = vault.current_vault_interest_unit(clock);
    let position = vault.position_table.borrow(debtor);
    (
        position.coll_amount,
        position.debt_amount + position.interest_amount(current_vault_interest_unit)
    )
}

public fun try_get_position_data<T>(vault: &Vault<T>, debtor: address, clock: &Clock): (u64, u64) {
    if (vault.position_table.contains(debtor)) {
    let current_vault_interest_unit = vault.current_vault_interest_unit(clock);
    let position = vault.position_table.borrow(debtor);
    (
        position.coll_amount,
        position.debt_amount + position.interest_amount(current_vault_interest_unit)
    )
    } else {
        (0, 0)
    }
}

/// Get raw position data (collateral, debt, timestamp) for a debtor
public fun get_raw_position_data<T>(vault: &Vault<T>, debtor: address): (u64, u64, Double) {
    let table = vault.position_table();
    if (!table.contains(debtor)) {
        err_debtor_not_found();
    };
    let position = table.borrow(debtor);
    (
        position.coll_amount,
        position.debt_amount,
        position.interest_unit,
    )
}

/// Get the vault's object ID
public fun id<T>(vault: &Vault<T>): ID {
    object::id(vault)
}

/// Display Funs

/// Struct for displaying position data
public struct PositionData has copy, drop {
    debtor: address,
    coll_amount: u64,
    debt_amount: u64,
}

/// Get a paginated list of positions in the vault
public fun get_positions<T>(
    vault: &Vault<T>,
    clock: &Clock,
    mut cursor: Option<address>,
    page_size: u64,
): (vector<PositionData>, Option<address>) {
    let mut pos_data_vec = vector[];
    let table = &vault.position_table;
    if (cursor.is_none()) {
        cursor = *table.front();
    };
    let mut counter = 0;
    while (cursor.is_some() && counter < page_size) {
        let debtor = *cursor.borrow();
        let (coll_amount, debt_amount) = vault.get_position_data(debtor, clock);
        pos_data_vec.push_back(PositionData {
            debtor, coll_amount, debt_amount,
        });
        counter = counter + 1;
        cursor = *table.next(debtor);
    };
    (pos_data_vec, cursor)
}

public use fun position_data as PositionData.data;
/// Get tuple of (debtor, collateral, debt) from PositionData
public fun position_data(position: &PositionData): (address, u64, u64) {
    (position.debtor, position.coll_amount, position.debt_amount)
}

/// Internal Funs

/// Mint USDB to a user, increasing the vault's supply counter
fun mint_usdb<T>(vault: &mut Vault<T>, treasury: &mut Treasury, amount: u64, ctx: &mut TxContext): Coin<USDB> {
    vault.limited_supply.increase(amount);
    treasury.mint(witness(), package_version(), amount, ctx)
}

/// Burn USDB from a user, decreasing the vault's supply counter
fun burn_usdb<T>(vault: &mut Vault<T>, treasury: &mut Treasury, coin: Coin<USDB>) {
    vault.limited_supply.decrease(coin.value());
    treasury.burn(witness(), package_version(), coin);
}

fun current_vault_interest_unit<T>(vault: &Vault<T>, clock: &Clock): Double {
    if (vault.total_debt_amount > 0) {
        let current_timestamp = clock.timestamp_ms();
        let duration = current_timestamp - vault.timestamp;
        vault.interest_unit.add(
            vault.interest_rate
            .mul(double::from_fraction(duration, one_year()))
        )
    } else {
        vault.interest_unit
    }
}

/// Calculate interest accrued on a position since last update
fun interest_amount(position: &Position, vault_interest_unit: Double): u64 {
    let unit_diff = vault_interest_unit.sub(position.interest_unit);
    unit_diff.mul_u64(position.debt_amount).ceil()
}

/// Accrue interest to a position, updating its debt and timestamp
fun accrue_interest<T>(
    vault: &mut Vault<T>,
    position: &mut Position,
    treasury: &mut Treasury,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let current_vault_interest_unit = vault.collect_interest(treasury, clock, ctx);
    let interest_amount = position.interest_amount(current_vault_interest_unit);
    position.debt_amount = position.debt_amount + interest_amount;
    position.interest_unit = vault.current_vault_interest_unit(clock);
    interest_amount
}

/// Constant: milliseconds in one year
fun one_year(): u64 { 31_536_000_000 }


/// check vault security level
fun check_security_level<T>(vault: &Vault<T>, level: u8) {
    if(vault.security_level.is_some() && level >= *vault.security_level.borrow()) err_against_security_level();
}

/// check if the position is locked
fun assert_position_is_not_locked<T>(vault: &Vault<T>, account: address) {
    if (vault.position_locker.contains(&account)) {
        err_position_is_locked();
    }
}
