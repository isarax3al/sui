#[test_only]
module bucket_v2_psm::bucket_v2_psm_tests {
    use bucket_v2_framework::{double::{Self, Double}, float::{Self, Float}, account};
    use bucket_v2_oracle::result as price_result;
    use bucket_v2_psm::{pool::{Self, Pool}, witness::BucketV2PSM};
    use bucket_v2_usd::{
        admin::AdminCap,
        bucket_v2_usd_tests::{Self, admin},
        usdb::{Self, USDB, Treasury}
    };
    use sui::{coin, clock::{Self, Clock}, test_scenario::{Self as ts, Scenario}};

    public fun start_timestamp(): u64 { 1745301421843 }

    public fun min_collateral_ratio(): Float { float::from_percent(110) }

    public fun interest_rate(): Double { double::from_bps(5_50) }

    public fun sui(amount: u64): u64 { amount * 1_000_000_000 }

    public fun usdb(amount: u64): u64 { amount * 10u64.pow(usdb::decimal()) }

    public fun one_year(): u64 { 31_536_000_000 }

    public struct USDC has drop {}

    const USDC_DECIMALS: u8 = 6;

    public struct MOCK_STABLE has drop {}

    const MOCK_STABLE_DECIMALS: u8 = 9;

    public struct MOCK_SMALL_STALBE has drop {}

    const MOCK_SMALL_STALBE_DECIMALS: u8 = 3;

    public fun setup(supply_limit: u64): Scenario {
        bucket_v2_usd_tests::setup<BucketV2PSM>(1, supply_limit)
    }

    public fun create_pool<T>(
        s: &mut Scenario,
        decimal: u8,
        swap_in_fee_bps: u64,
        swap_out_fee_bps: u64,
    ) {
        s.next_tx(admin());
        {
            let cap = s.take_from_sender<AdminCap>();
            let treasury = s.take_shared<Treasury>();
            let mut clock = clock::create_for_testing(s.ctx());
            clock.set_for_testing(start_timestamp());
            pool::create<T>(
                &treasury,
                &cap,
                decimal,
                swap_in_fee_bps,
                swap_out_fee_bps,
                5, // price_tolerance
                s.ctx(),
            );
            clock.share_for_testing();
            s.return_to_sender(cap);
            ts::return_shared(treasury);
        };

        s.next_tx(admin());
        {
            let pool = s.take_shared<Pool<T>>();

            assert!(pool.decimal() == decimal);
            assert!(pool.swap_in_fee_rate(option::none()) == float::from_bps(swap_in_fee_bps));
            assert!(pool.swap_out_fee_rate(option::none()) == float::from_bps(swap_out_fee_bps));
            assert!(pool.balance() == 0);
            assert!(pool.balance_amount() == 0);
            assert!(pool.price_tolerance() == float::from_bps(5));
            assert!(pool.usdb_supply() == 0);

            ts::return_shared(pool);
        };
    }

    public enum PoolSwapAction has drop {
        Normal,
        Partner,
    }

    public fun swap_in<T>(
        s: &mut Scenario,
        action: PoolSwapAction,
        user: address,
        collateral_amount: u64,
        current_price_bps: u64,
    ): (u64, u64) {
        s.next_tx(user);

        match (action) {
            PoolSwapAction::Normal => {
                let mut pool = s.take_shared<Pool<T>>();
                let mut treasury = s.take_shared<Treasury>();

                // prev state
                let prev_usdb_treasury = psm_treasury<USDB>(&treasury);
                let prev_pool_balance = pool.balance();
                let prev_pool_balance_amount = pool.balance_amount();

                let price = price_result::new_for_testing<T>(float::from_bps(current_price_bps));
                let collateral = coin::mint_for_testing<T>(collateral_amount, s.ctx());
                let usdb = pool.swap_in(
                    &mut treasury,
                    &price,
                    collateral,
                    &option::none(),
                    s.ctx(),
                );

                // check output amount
                let swap_in_fee_rate = pool.swap_in_fee_rate(option::none());
                let output_usdb = float::from(collateral_amount)
                    .mul(pool.conversion_rate())
                    .mul(float::from(1).sub(swap_in_fee_rate))
                    .floor();
                assert!(usdb.burn_for_testing() == output_usdb);
                // check fee in usdb
                let charged_fee = float::from(collateral_amount)
                    .mul(pool.conversion_rate())
                    .mul(swap_in_fee_rate)
                    .ceil();
                assert!(psm_treasury<USDB>(&treasury) == prev_usdb_treasury + charged_fee);
                assert!(pool.balance() == prev_pool_balance + collateral_amount);
                assert!(pool.balance_amount() == prev_pool_balance_amount + collateral_amount);

                ts::return_shared(treasury);
                ts::return_shared(pool);

                (output_usdb, charged_fee)
            },
            PoolSwapAction::Partner => {
                let mut pool = s.take_shared<Pool<T>>();
                let mut treasury = s.take_shared<Treasury>();

                // prev state
                let prev_usdb_treasury = psm_treasury<USDB>(&treasury);
                let prev_pool_balance = pool.balance();
                let prev_pool_balance_amount = pool.balance_amount();

                let price = price_result::new_for_testing<T>(float::from_bps(current_price_bps));
                let collateral = coin::mint_for_testing<T>(collateral_amount, s.ctx());
                let usdb = pool.swap_in(
                    &mut treasury,
                    &price,
                    collateral,
                    &option::some(account::request(s.ctx())),
                    s.ctx(),
                );

                // check output amount
                let swap_in_fee_rate = pool.swap_in_fee_rate(option::some(s.sender()));
                let output_usdb = float::from(collateral_amount)
                    .mul(pool.conversion_rate())
                    .mul(float::from(1).sub(swap_in_fee_rate))
                    .floor();
                assert!(usdb.burn_for_testing() == output_usdb);
                // check fee in usdb
                let charged_fee = float::from(collateral_amount)
                    .mul(pool.conversion_rate())
                    .mul(swap_in_fee_rate)
                    .ceil();
                assert!(psm_treasury<USDB>(&treasury) == prev_usdb_treasury + charged_fee);
                assert!(pool.balance() == prev_pool_balance + collateral_amount);
                assert!(pool.balance_amount() == prev_pool_balance_amount + collateral_amount);

                ts::return_shared(treasury);
                ts::return_shared(pool);

                (output_usdb, charged_fee)
            },
        }
    }

    public fun swap_out<T>(
        s: &mut Scenario,
        action: PoolSwapAction,
        user: address,
        usdb_input: u64,
        current_price_bps: u64,
    ): (u64, u64) {
        s.next_tx(user);

        match (action) {
            PoolSwapAction::Normal => {
                let mut pool = s.take_shared<Pool<T>>();
                let mut treasury = s.take_shared<Treasury>();

                // prev state
                let prev_collateral_treasury = psm_treasury<T>(&treasury);
                let prev_pool_balance = pool.balance();
                let prev_pool_balance_amount = pool.balance_amount();

                let price = price_result::new_for_testing<T>(float::from_bps(current_price_bps));
                let usdb = coin::mint_for_testing<USDB>(usdb_input, s.ctx());
                let stable = pool.swap_out(
                    &mut treasury,
                    &price,
                    usdb,
                    &option::none(),
                    s.ctx(),
                );

                // check returned stable coin
                let swap_out_fee_rate = pool.swap_out_fee_rate(option::none());
                let total_out = float::from(usdb_input).div(pool.conversion_rate()).floor();
                let output_stable = float::from(usdb_input)
                    .div(pool.conversion_rate())
                    .mul(float::from(1).sub(swap_out_fee_rate))
                    .floor();
                assert!(stable.burn_for_testing() == output_stable);
                // check fee in collateral
                let charged_fee = float::from(usdb_input)
                    .div(pool.conversion_rate())
                    .mul(swap_out_fee_rate)
                    .ceil();
                assert!(psm_treasury<T>(&treasury) ==  prev_collateral_treasury + charged_fee);
                assert!(pool.balance() == prev_pool_balance - total_out);
                assert!(pool.balance_amount() == prev_pool_balance_amount - total_out);

                ts::return_shared(treasury);
                ts::return_shared(pool);

                (output_stable, charged_fee)
            },
            PoolSwapAction::Partner => {
                let mut pool = s.take_shared<Pool<T>>();
                let mut treasury = s.take_shared<Treasury>();

                // prev state
                let prev_collateral_treasury = psm_treasury<T>(&treasury);
                let prev_pool_balance = pool.balance();
                let prev_pool_balance_amount = pool.balance_amount();

                let price = price_result::new_for_testing<T>(float::from_bps(current_price_bps));
                let usdb = coin::mint_for_testing<USDB>(usdb_input, s.ctx());
                let stable = pool.swap_out(
                    &mut treasury,
                    &price,
                    usdb,
                    &option::some(account::request(s.ctx())),
                    s.ctx(),
                );

                // check returned stable coin
                let swap_out_fee_rate = pool.swap_out_fee_rate(option::some(s.sender()));
                let total_out = float::from(usdb_input).div(pool.conversion_rate()).floor();
                let output_stable = float::from(usdb_input)
                    .div(pool.conversion_rate())
                    .mul(float::from(1).sub(swap_out_fee_rate))
                    .floor();
                assert!(stable.burn_for_testing() == output_stable);
                // check fee in collateral
                let charged_fee = float::from(usdb_input)
                    .div(pool.conversion_rate())
                    .mul(swap_out_fee_rate)
                    .ceil();
                assert!(psm_treasury<T>(&treasury) ==  prev_collateral_treasury + charged_fee);
                assert!(pool.balance() == prev_pool_balance - total_out);
                assert!(pool.balance_amount() == prev_pool_balance_amount - total_out);

                ts::return_shared(treasury);
                ts::return_shared(pool);

                (output_stable, charged_fee)
            },
        }
    }

    public fun time_pass(s: &mut Scenario, tick: u64) {
        s.next_tx(@0x0);
        let mut clock = s.take_shared<Clock>();
        clock.increment_for_testing(tick);
        ts::return_shared(clock);
    }

    public fun psm_treasury<T>(treasury: &Treasury): u64 {
        if (!treasury.is_claimable_map_exists_type<T>()) {
            0
        } else {
            let map = treasury.claimable_map<T>();
            let witness = std::type_name::get<BucketV2PSM>();
            if (map.contains(&witness)) {
                map[&witness].value()
            } else {
                0
            }
        }
    }

    #[test]
    fun test_pool_main_(): Scenario {
        // 1M
        let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = setup(supply_limit);
        let s = &mut scenario;
        let decimal = 6;
        // 0.1%
        let swap_in_fee_bps = 10; // bps
        // 0.2%
        let swap_out_fee_bps = 20; // bps
        create_pool<USDC>(
            s,
            decimal,
            swap_in_fee_bps,
            swap_out_fee_bps,
        );

        // swap_in
        let user = @0x123;
        let collateral_amount = 1_000_000 * 10_u64.pow(USDC_DECIMALS);
        let current_price_bps = 10000;
        let (usdb, fee) = swap_in<USDC>(
            s,
            PoolSwapAction::Normal,
            user,
            collateral_amount,
            current_price_bps,
        );
        assert!(usdb == 999_000 * 10_u64.pow(usdb::decimal()));
        assert!(fee == 1_000 * 10_u64.pow(usdb::decimal()));

        // swap_out
        let user = @0x123;
        let usdb_input = 1_000_000 * 10_u64.pow(usdb::decimal());
        let current_price_bps = 10000;
        let (stable, fee) = swap_out<USDC>(
            s,
            PoolSwapAction::Normal,
            user,
            usdb_input,
            current_price_bps,
        );
        assert!(stable == 998_000 * 10_u64.pow(USDC_DECIMALS));
        assert!(fee == 2_000 * 10_u64.pow(USDC_DECIMALS));

        scenario
    }

    #[test]
    fun test_pool_main_with_decimal_9() {
        // 1M
        let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = setup(supply_limit);
        let s = &mut scenario;
        let decimal = 9;
        // 0.1%
        let swap_in_fee_bps = 10; // bps
        // 0.2%
        let swap_out_fee_bps = 20; // bps
        create_pool<MOCK_STABLE>(
            s,
            decimal,
            swap_in_fee_bps,
            swap_out_fee_bps,
        );

        // swap_in
        let user = @0x123;
        let collateral_amount = 1_000_000 * 10_u64.pow(MOCK_STABLE_DECIMALS);
        let current_price_bps = 10000;
        let (usdb, fee) = swap_in<MOCK_STABLE>(
            s,
            PoolSwapAction::Normal,
            user,
            collateral_amount,
            current_price_bps,
        );
        assert!(usdb == 999_000 * 10_u64.pow(usdb::decimal()));
        assert!(fee == 1_000 * 10_u64.pow(usdb::decimal()));

        // swap_out
        let user = @0x123;
        let usdb_input = 1_000_000 * 10_u64.pow(usdb::decimal());
        let current_price_bps = 10000;
        let (stable, fee) = swap_out<MOCK_STABLE>(
            s,
            PoolSwapAction::Normal,
            user,
            usdb_input,
            current_price_bps,
        );
        assert!(stable == 998_000 * 10_u64.pow(MOCK_STABLE_DECIMALS));
        assert!(fee == 2_000 * 10_u64.pow(MOCK_STABLE_DECIMALS));

        scenario.end();
    }

    #[test]
    fun test_pool_main_with_decimal_3() {
        // 1M
        let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = setup(supply_limit);
        let s = &mut scenario;
        let decimal = 3;
        // 0.1%
        let swap_in_fee_bps = 10; // bps
        // 0.2%
        let swap_out_fee_bps = 20; // bps
        create_pool<MOCK_SMALL_STALBE>(
            s,
            decimal,
            swap_in_fee_bps,
            swap_out_fee_bps,
        );

        // swap_in
        let user = @0x123;
        let collateral_amount = 1_000_000 * 10_u64.pow(MOCK_SMALL_STALBE_DECIMALS);
        let current_price_bps = 10000;
        let (usdb, fee) = swap_in<MOCK_SMALL_STALBE>(
            s,
            PoolSwapAction::Normal,
            user,
            collateral_amount,
            current_price_bps,
        );
        assert!(usdb == 999_000 * 10_u64.pow(usdb::decimal()));
        assert!(fee == 1_000 * 10_u64.pow(usdb::decimal()));

        // swap_out
        let user = @0x123;
        let usdb_input = 1_000_000 * 10_u64.pow(usdb::decimal());
        let current_price_bps = 10000;
        let (stable, fee) = swap_out<MOCK_SMALL_STALBE>(
            s,
            PoolSwapAction::Normal,
            user,
            usdb_input,
            current_price_bps,
        );
        assert!(stable == 998_000 * 10_u64.pow(MOCK_SMALL_STALBE_DECIMALS));
        assert!(fee == 2_000 * 10_u64.pow(MOCK_SMALL_STALBE_DECIMALS));

        scenario.end();
    }

    #[test]
    fun test_pool_main_update_rate() {
        let mut scenario = test_pool_main_();
        let s = &mut scenario;

        s.next_tx(admin());
        {
            let mut pool = s.take_shared<Pool<USDC>>();
            let cap = s.take_from_sender<AdminCap>();

            // double all the rate
            pool.set_fee_config(&cap, option::none(), 20, 40);

            s.return_to_sender(cap);
            ts::return_shared(pool);
        };

        // swap_in
        let user = @0x123;
        let collateral_amount = 1_000_000 * 10_u64.pow(USDC_DECIMALS);
        let current_price_bps = 10000;
        let (usdb, fee) = swap_in<USDC>(
            s,
            PoolSwapAction::Normal,
            user,
            collateral_amount,
            current_price_bps,
        );
        assert!(usdb == 998_000 * 10_u64.pow(usdb::decimal()));
        assert!(fee == 2_000 * 10_u64.pow(usdb::decimal()));

        // swap_out
        let user = @0x123;
        let usdb_input = 1_000_000 * 10_u64.pow(usdb::decimal());
        let current_price_bps = 10000;
        let (stable, fee) = swap_out<USDC>(
            s,
            PoolSwapAction::Normal,
            user,
            usdb_input,
            current_price_bps,
        );
        assert!(stable == 996_000 * 10_u64.pow(USDC_DECIMALS));
        assert!(fee == 4_000 * 10_u64.pow(USDC_DECIMALS));

        scenario.end();
    }

    #[test, expected_failure(abort_code = bucket_v2_usd::limited_supply::ESupplyExceedLimit)]
    fun test_exceed_limit_err() {
        let mut scenario = test_pool_main_();
        let s = &mut scenario;

        // swap_in
        let user = @0x123;
        let collateral_amount = 1_000_000 * 10_u64.pow(USDC_DECIMALS);
        let current_price_bps = 10000;
        swap_in<USDC>(
            s,
            PoolSwapAction::Normal,
            user,
            collateral_amount + 1,
            current_price_bps,
        );

        scenario.end();
    }

    #[test, expected_failure(abort_code = bucket_v2_psm::pool::EPoolNotEnough)]
    fun test_swap_out_with_insufficient_pool() {
        // 1M
        let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = setup(supply_limit);
        let s = &mut scenario;

        // USDC
        let decimal = 6;
        // 0.1%
        let swap_in_fee_bps = 10; // bps
        // 0.2%
        let swap_out_fee_bps = 20; // bps
        create_pool<USDC>(
            s,
            decimal,
            swap_in_fee_bps,
            swap_out_fee_bps,
        );

        let user = @0x123;
        let collateral_amount = 500_000 * 10_u64.pow(USDC_DECIMALS);
        let current_price_bps = 10000;
        swap_in<USDC>(
            s,
            PoolSwapAction::Normal,
            user,
            collateral_amount,
            current_price_bps,
        );

        // MOCK_STABLE
        let decimal = 9;
        // 0.1%
        let swap_in_fee_bps = 10; // bps
        // 0.2%
        let swap_out_fee_bps = 20; // bps
        create_pool<MOCK_STABLE>(
            s,
            decimal,
            swap_in_fee_bps,
            swap_out_fee_bps,
        );

        let user = @0x123;
        let collateral_amount = 500_000 * 10_u64.pow(MOCK_STABLE_DECIMALS);
        let current_price_bps = 10000;
        swap_in<MOCK_STABLE>(
            s,
            PoolSwapAction::Normal,
            user,
            collateral_amount,
            current_price_bps,
        );

        // swap_out
        let user = @0x123;
        let usdb_input = 1_000_000 * 10_u64.pow(usdb::decimal());
        let current_price_bps = 10000;
        let (stable, fee) = swap_out<USDC>(
            s,
            PoolSwapAction::Normal,
            user,
            usdb_input,
            current_price_bps,
        );
        assert!(stable == 998_000 * 10_u64.pow(USDC_DECIMALS));
        assert!(fee == 2_000 * 10_u64.pow(USDC_DECIMALS));

        scenario.end();
    }

    fun setup_partner_config_(account: address): Scenario {
        // 1M
        let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = setup(supply_limit);
        let s = &mut scenario;
        let decimal = 6;
        // 0.1%
        let swap_in_fee_bps = 10; // bps
        // 0.2%
        let swap_out_fee_bps = 20; // bps
        create_pool<USDC>(
            s,
            decimal,
            swap_in_fee_bps,
            swap_out_fee_bps,
        );

        // setup partner config
        s.next_tx(admin());
        {
            let treasury = s.take_shared<Treasury>();
            let cap = s.take_from_sender<AdminCap>();
            let mut pool = s.take_shared<Pool<USDC>>();

            // 0.05%
            let swap_in_fee_bps = 5; // bps
            // 0.1%
            let swap_out_fee_bps = 10; // bps
            pool.set_fee_config<USDC>(
                &cap,
                option::some(account),
                swap_in_fee_bps,
                swap_out_fee_bps,
            );

            s.return_to_sender(cap);
            ts::return_shared(pool);
            ts::return_shared(treasury);
        };

        scenario
    }

    #[test]
    fun test_pool_with_partner_main(): Scenario {
        let user = @0x123;
        let mut scenario = setup_partner_config_(user);
        let s = &mut scenario;

        // swap_in with partner
        let collateral_amount = 1_000_000 * 10_u64.pow(USDC_DECIMALS);
        let current_price_bps = 10000;
        let (usdb, fee) = swap_in<USDC>(
            s,
            PoolSwapAction::Partner,
            user,
            collateral_amount,
            current_price_bps,
        );
        assert!(usdb == 999_500 * 10_u64.pow(usdb::decimal()));
        assert!(fee == 500 * 10_u64.pow(usdb::decimal()));

        // swap_out
        let user = @0x123;
        let usdb_input = 1_000_000 * 10_u64.pow(usdb::decimal());
        let current_price_bps = 10000;
        let (stable, fee) = swap_out<USDC>(
            s,
            PoolSwapAction::Partner,
            user,
            usdb_input,
            current_price_bps,
        );
        assert!(stable == 999_000 * 10_u64.pow(USDC_DECIMALS));
        assert!(fee == 1_000 * 10_u64.pow(USDC_DECIMALS));

        scenario
    }

    #[test]
    fun test_fluctuating_price_with_upward_direction() {
        // 1M
        let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = setup(supply_limit);
        let s = &mut scenario;
        let decimal = 6;
        // 0.1%
        let swap_in_fee_bps = 10; // bps
        // 0.2%
        let swap_out_fee_bps = 20; // bps
        create_pool<USDC>(
            s,
            decimal,
            swap_in_fee_bps,
            swap_out_fee_bps,
        );

        // swap_in
        let user = @0x123;
        let collateral_amount = 1_000_000 * 10_u64.pow(USDC_DECIMALS);
        // price move upward 5 bps
        let current_price_bps = 10005;
        let (usdb, fee) = swap_in<USDC>(
            s,
            PoolSwapAction::Normal,
            user,
            collateral_amount,
            current_price_bps,
        );
        assert!(usdb == 999_000 * 10_u64.pow(usdb::decimal()));
        assert!(fee == 1_000 * 10_u64.pow(usdb::decimal()));

        scenario.end();
    }

    #[test, expected_failure(abort_code = bucket_v2_psm::pool::EFluctuatingPrice)]
    fun test_fluctuating_upward_price_out_of_tolerance_err() {
        // 1M
        let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = setup(supply_limit);
        let s = &mut scenario;
        let decimal = 6;
        // 0.1%
        let swap_in_fee_bps = 10; // bps
        // 0.2%
        let swap_out_fee_bps = 20; // bps
        create_pool<USDC>(
            s,
            decimal,
            swap_in_fee_bps,
            swap_out_fee_bps,
        );

        // swap_in
        let user = @0x123;
        let collateral_amount = 1_000_000 * 10_u64.pow(USDC_DECIMALS);
        // price move upward 10 bps
        let current_price_bps = 10010;
        let (usdb, fee) = swap_in<USDC>(
            s,
            PoolSwapAction::Normal,
            user,
            collateral_amount,
            current_price_bps,
        );
        assert!(usdb == 999_000 * 10_u64.pow(usdb::decimal()));
        assert!(fee == 1_000 * 10_u64.pow(usdb::decimal()));

        scenario.end();
    }

    #[test]
    fun test_fluctuating_price_with_downward_direction() {
        // 1M
        let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = setup(supply_limit);
        let s = &mut scenario;
        let decimal = 6;
        // 0.1%
        let swap_in_fee_bps = 10; // bps
        // 0.2%
        let swap_out_fee_bps = 20; // bps
        create_pool<USDC>(
            s,
            decimal,
            swap_in_fee_bps,
            swap_out_fee_bps,
        );

        // swap_in
        let user = @0x123;
        let collateral_amount = 1_000_000 * 10_u64.pow(USDC_DECIMALS);
        // price move upward 5 bps
        let current_price_bps = 9995;
        let (usdb, fee) = swap_in<USDC>(
            s,
            PoolSwapAction::Normal,
            user,
            collateral_amount,
            current_price_bps,
        );
        assert!(usdb == 999_000 * 10_u64.pow(usdb::decimal()));
        assert!(fee == 1_000 * 10_u64.pow(usdb::decimal()));

        scenario.end();
    }

    #[test, expected_failure(abort_code = bucket_v2_psm::pool::EFluctuatingPrice)]
    fun test_fluctuating_downward_price_out_of_tolerance_err() {
        // 1M
        let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = setup(supply_limit);
        let s = &mut scenario;
        let decimal = 6;
        // 0.1%
        let swap_in_fee_bps = 10; // bps
        // 0.2%
        let swap_out_fee_bps = 20; // bps
        create_pool<USDC>(
            s,
            decimal,
            swap_in_fee_bps,
            swap_out_fee_bps,
        );

        // swap_in
        let user = @0x123;
        let collateral_amount = 1_000_000 * 10_u64.pow(USDC_DECIMALS);
        // price move upward 10 bps
        let current_price_bps = 99990;
        let (usdb, fee) = swap_in<USDC>(
            s,
            PoolSwapAction::Normal,
            user,
            collateral_amount,
            current_price_bps,
        );
        assert!(usdb == 999_000 * 10_u64.pow(usdb::decimal()));
        assert!(fee == 1_000 * 10_u64.pow(usdb::decimal()));

        scenario.end();
    }
}
