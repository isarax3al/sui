module bucket_v2_psm::pool {

    use bucket_v2_framework::float::{Self, Float};
    use bucket_v2_framework::account::{AccountRequest};
    use bucket_v2_framework::sheet::{Self, Sheet};
    use bucket_v2_oracle::result::PriceResult;
    use bucket_v2_psm::{events, memo, version, witness::{witness, BucketV2PSM}, version::package_version};
    use bucket_v2_usd::{
        admin::AdminCap,
        usdb::{Treasury, USDB, decimal as usdb_decimal}
    };
    use sui::{balance::{Self, Balance}, coin::{Coin}, vec_map::{Self, VecMap}};

    /// Errors

    const EPoolNotEnough: u64 = 401;
    fun err_pool_not_enough() { abort EPoolNotEnough }

    const EFluctuatingPrice: u64 = 402;
    fun err_fluctuating_price() { abort EFluctuatingPrice }

    /// Struct

    public struct FeeConfig has copy, drop, store {
        swap_in_fee_rate: Float,
        swap_out_fee_rate: Float,
    }

    /// Objects

    public struct Pool<phantom T> has key, store {
        id: UID,
        // configs
        decimal: u8,
        default_fee_config: FeeConfig,
        partner_fee_configs: VecMap<address, FeeConfig>,
        price_tolerance: Float,
        // states
        balance: Balance<T>,
        balance_amount: u64,
        usdb_supply: u64,
        sheet: Sheet<T, BucketV2PSM>,
    }

    /// Admin Funs

    public fun new<T>(
        treasury: &Treasury,
        _cap: &AdminCap,
        decimal: u8,
        swap_in_fee_rate_bps: u64,
        swap_out_fee_rate_bps: u64,
        price_tolerance_bps: u64,
        ctx: &mut TxContext,
    ): Pool<T> {
        version::assert_valid_package(treasury);

        let id = object::new(ctx);
        events::emit_new_pool<T>(
            id.to_inner(),
            decimal,
            swap_in_fee_rate_bps,
            swap_out_fee_rate_bps,
        );
        let default_fee_config = FeeConfig {
            swap_in_fee_rate: float::from_bps(swap_in_fee_rate_bps),
            swap_out_fee_rate: float::from_bps(swap_out_fee_rate_bps),
        };
        Pool<T> {
            id,
            decimal,
            default_fee_config,
            partner_fee_configs: vec_map::empty(),
            price_tolerance: float::from_bps(price_tolerance_bps),
            balance: balance::zero(),
            balance_amount: 0,
            usdb_supply: 0,
            sheet: sheet::new(witness()),
        }
    }

    #[allow(lint(share_owned))]
    public fun create<T>(
        treasury: &Treasury,
        _cap: &AdminCap,
        decimal: u8,
        swap_in_fee_rate_bps: u64,
        swap_out_fee_rate_bps: u64,
        price_tolerance_bps: u64,
        ctx: &mut TxContext,
    ) {
        let pool = new<T>(
            treasury,
            _cap,
            decimal,
            swap_in_fee_rate_bps,
            swap_out_fee_rate_bps,
            price_tolerance_bps,
            ctx,
        );
        transfer::share_object(pool);
    }

    public fun set_fee_config<T>(
        pool: &mut Pool<T>,
        _cap: &AdminCap,
        partner: Option<address>,
        swap_in_fee_rate_bps: u64,
        swap_out_fee_rate_bps: u64,
    ) {
        if (partner.is_some()) {
            let partner_address = partner.destroy_some();
            if (pool.partner_fee_configs.contains(&partner_address)) {
                let config = &mut pool.partner_fee_configs[&partner_address];
                config.swap_in_fee_rate = float::from_bps(swap_in_fee_rate_bps);
                config.swap_out_fee_rate = float::from_bps(swap_out_fee_rate_bps);
            } else {
                pool.partner_fee_configs.insert(partner_address, FeeConfig {
                    swap_in_fee_rate: float::from_bps(swap_in_fee_rate_bps),
                    swap_out_fee_rate: float::from_bps(swap_out_fee_rate_bps),
                });
            }
        } else {
            pool.default_fee_config.swap_in_fee_rate = float::from_bps(swap_in_fee_rate_bps);
            pool.default_fee_config.swap_out_fee_rate = float::from_bps(swap_out_fee_rate_bps);
        }
    }

    public fun set_price_tolerance<T>(pool: &mut Pool<T>, _cap: &AdminCap, tolerance_bps: u64) {
        pool.price_tolerance = float::from_bps(tolerance_bps);
    }

    /// Public Funs

    public fun swap_in<T>(
        pool: &mut Pool<T>,
        treasury: &mut Treasury,
        price: &PriceResult<T>,
        asset_coin: Coin<T>,
        partner: &Option<AccountRequest>,
        ctx: &mut TxContext,
    ): Coin<USDB> {
        version::assert_valid_package(treasury);
        pool.check_price(price);

        let fee_rate = pool.swap_in_fee_rate(partner.map_ref!(|p| p.address()));
        pool.swap_in_internal(treasury, asset_coin, fee_rate, ctx)
    }

    public fun swap_out<T>(
        pool: &mut Pool<T>,
        treasury: &mut Treasury,
        price: &PriceResult<T>,
        usdb_coin: Coin<USDB>,
        partner: &Option<AccountRequest>,
        ctx: &mut TxContext,
    ): Coin<T> {
        version::assert_valid_package(treasury);
        pool.check_price(price);

        let fee_rate = pool.swap_out_fee_rate(partner.map_ref!(|p| p.address()));
        pool.swap_out_internal(treasury, usdb_coin, fee_rate, ctx)
    }

    // Getter Funs

    public fun decimal<T>(pool: &Pool<T>): u8 {
        pool.decimal
    }

    // scaling factor for conversing collateral assets to USDB
    public fun conversion_rate<T>(pool: &Pool<T>): Float {
        let usdb_decimal = usdb_decimal();
        if (usdb_decimal >= pool.decimal) {
            float::ten().pow((usdb_decimal - pool.decimal) as u64)
        } else {
            float::one().div(
                float::ten().pow((pool.decimal - usdb_decimal) as u64)
            )
        }
    }

    public fun swap_in_fee_rate<T>(pool: &Pool<T>, partner: Option<address>): Float {
        if (partner.is_some() && pool.partner_fee_configs.contains(partner.borrow())) {
            pool.partner_fee_configs[partner.borrow()].swap_in_fee_rate
        } else {
            pool.default_fee_config.swap_in_fee_rate
        }
    }

    public fun swap_out_fee_rate<T>(pool: &Pool<T>, partner: Option<address>): Float {
        if (partner.is_some() && pool.partner_fee_configs.contains(partner.borrow())) {
            pool.partner_fee_configs[partner.borrow()].swap_out_fee_rate
        } else {
            pool.default_fee_config.swap_out_fee_rate
        }
    }

    public fun balance<T>(pool: &Pool<T>): u64 {
        pool.balance.value()
    }

    public fun balance_amount<T>(pool: &Pool<T>): u64 {
        pool.balance_amount
    }

    public fun usdb_supply<T>(pool: &Pool<T>): u64 {
        pool.usdb_supply
    }

    public fun price_tolerance<T>(pool: &Pool<T>): Float {
        pool.price_tolerance
    }

    /// Internal Funs
    fun swap_in_internal<T>(
        pool: &mut Pool<T>,
        treasury: &mut Treasury,
        asset_coin: Coin<T>,
        fee_rate: Float,
        ctx: &mut TxContext,
    ): Coin<USDB> {
        let asset_in_amount = asset_coin.value();

        // calculate output USDB amount
        let usdb_out_amount = float::from(asset_in_amount).mul(pool.conversion_rate()).floor();
        // collect asset
        pool.balance_amount = pool.balance.join(asset_coin.into_balance());
        pool.usdb_supply = pool.usdb_supply + usdb_out_amount;
        // emit event
        if (asset_in_amount > 0 || usdb_out_amount > 0) {
            events::emit_swap_in<T>(asset_in_amount, pool.balance_amount, usdb_out_amount, pool.usdb_supply);
        };
        // mint USDB
        let mut output = treasury.mint(witness(), version::package_version(), usdb_out_amount, ctx);
        // split fee and collect
        let fee_amount = fee_rate.mul_u64(usdb_out_amount).ceil();
        let fee = output.balance_mut().split(fee_amount);
        treasury.collect(witness(), memo::swap_in(), fee);

        output
    }

    fun swap_out_internal<T>(
        pool: &mut Pool<T>,
        treasury: &mut Treasury,
        usdb_coin: Coin<USDB>,
        fee_rate: Float,
        ctx: &mut TxContext,
    ): Coin<T> {
        let usdb_in_amount = usdb_coin.value();

        // burn USDB
        treasury.burn(witness(), package_version(), usdb_coin);
        let asset_out_amount = float::from(usdb_in_amount).div(pool.conversion_rate()).floor();
        if (asset_out_amount > pool.balance()) err_pool_not_enough();
        if (pool.usdb_supply < usdb_in_amount) err_pool_not_enough();
        pool.usdb_supply = pool.usdb_supply - usdb_in_amount;
        // take asset
        let mut asset = pool.balance.split(asset_out_amount).into_coin(ctx);
        pool.balance_amount = pool.balance.value();
        // emit event
        if (usdb_in_amount > 0 || asset_out_amount > 0) {
            events::emit_swap_out<T>(usdb_in_amount, pool.usdb_supply, asset_out_amount, pool.balance_amount);
        };
        let asset_amount = asset.value();
        // split fee and collect
        let fee_amount = fee_rate.mul_u64(asset_amount).ceil();
        let fee = asset.balance_mut().split(fee_amount);

        treasury.collect(witness(), memo::swap_out(), fee);

        asset
    }

    fun check_price<T>(pool: &Pool<T>, price: &PriceResult<T>) {
        let price = price.aggregated_price();
        if (price.diff(float::one()).gt(pool.price_tolerance())) {
            err_fluctuating_price();
        };
    }
}
