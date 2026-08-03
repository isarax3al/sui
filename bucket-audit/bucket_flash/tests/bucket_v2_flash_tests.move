#[test_only]
module bucket_v2_flash::bucket_v2_flash_tests {
    use bucket_v2_flash::{config::{Self, GlobalConfig}, witness::BucketV2Flash};
    use bucket_v2_framework::{account, float};
    use bucket_v2_usd::{
        admin::AdminCap,
        usdb::{Self, Treasury},
        bucket_v2_usd_tests::{Self, admin}
    };
    use sui::{
        coin::{burn_for_testing as burn_coin, mint_for_testing as mint_coin},
        test_scenario::{Self as ts, Scenario}
    };

    public fun setup(supply_limit: u64): Scenario {
        let mut scenario = bucket_v2_usd_tests::setup<BucketV2Flash>(1, supply_limit);

        config::init_for_testing(scenario.ctx());

        scenario.next_tx(admin());
        {
            let config = scenario.take_shared<GlobalConfig>();

            assert!(config.fee_rate(option::none()) == float::from_bps(0));
            assert!(config.max_amount(option::none()) == 0);
            assert!(config.total_amount(option::none()) == 0);

            ts::return_shared(config);
        };
        scenario
    }

    #[test]
    fun test_config_main() {
        // 100 M
        let supply_limit = 100_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = setup(supply_limit);
        let s = &mut scenario;

        // update config params
        s.next_tx(admin());
        {
            let cap = s.take_from_sender<AdminCap>();
            let mut config = s.take_shared<GlobalConfig>();
            let treasury = s.take_shared<Treasury>();

            let fee_rate = 5; // 4bps
            let max_amount = 1_000_000 * 10_u64.pow(usdb::decimal()); // 1M
            config.set_flash_config(&cap, option::none(), fee_rate, max_amount);

            assert!(config.fee_rate(option::none()) == float::from_bps(fee_rate));
            assert!(config.max_amount(option::none()) == max_amount);
            assert!(config.total_amount(option::none()) == 0);

            s.return_to_sender(cap);
            ts::return_shared(treasury);
            ts::return_shared(config);
        };

        // flash mint with default config
        s.next_tx(admin());
        {
            let mut config = s.take_shared<GlobalConfig>();
            let mut treasury = s.take_shared<Treasury>();

            let mint_amount = 1_000_000 * 10_u64.pow(usdb::decimal());
            let (usdb, receipt) = config.flash_mint(
                &mut treasury,
                &option::none(),
                mint_amount,
                s.ctx(),
            );
            assert!(burn_coin(usdb) == mint_amount);
            assert!(receipt.mint_amount() == mint_amount);

            assert!(config.total_amount(option::none()) == mint_amount);

            let fee_amount = float::from(mint_amount).mul(config.fee_rate(option::none())).ceil();
            assert!(receipt.fee_amount() == fee_amount);
            config.flash_burn(
                &mut treasury,
                mint_coin(mint_amount + fee_amount, s.ctx()),
                receipt,
            );

            assert!(config.total_amount(option::none()) == 0);

            ts::return_shared(treasury);
            ts::return_shared(config);
        };

        // update partner config params
        let partner = @0x123;
        s.next_tx(admin());
        {
            let cap = s.take_from_sender<AdminCap>();
            let mut config = s.take_shared<GlobalConfig>();
            let treasury = s.take_shared<Treasury>();

            let fee_rate = 1; // 1bps
            let max_amount = 100_000_000 * 10_u64.pow(usdb::decimal()); // 100M
            config.set_flash_config(&cap, option::some(partner), fee_rate * 2, max_amount * 3);
            config.set_flash_config(&cap, option::some(partner), fee_rate, max_amount);

            // default
            assert!(config.fee_rate(option::none()) == float::from_bps(5));
            assert!(config.max_amount(option::none()) == 1_000_000 * 10_u64.pow(usdb::decimal()));
            assert!(config.total_amount(option::none()) == 0);
            // partner
            assert!(config.fee_rate(option::some(partner)) == float::from_bps(1));
            assert!(config.max_amount(option::some(partner)) == max_amount);
            assert!(config.total_amount(option::some(partner)) == 0);

            s.return_to_sender(cap);
            ts::return_shared(treasury);
            ts::return_shared(config);
        };

        // flash mint with partner config
        s.next_tx(partner);
        {
            let mut config = s.take_shared<GlobalConfig>();
            let mut treasury = s.take_shared<Treasury>();

            let value = 100_000_000 * 10_u64.pow(usdb::decimal());
            let account_req = account::request(s.ctx());
            let (usdb, receipt) = config.flash_mint(
                &mut treasury,
                &option::some(account_req),
                value,
                s.ctx(),
            );
            assert!(burn_coin(usdb) == value);

            assert!(config.total_amount(option::none()) == 0);
            assert!(config.total_amount(option::some(partner)) == value);

            let fee = float::from(value).mul(config.fee_rate(option::some(partner))).ceil();

            config.flash_burn(
                &mut treasury,
                mint_coin(value + fee, s.ctx()),
                receipt,
            );

            assert!(config.total_amount(option::none()) == 0);
            assert!(config.total_amount(option::some(partner)) == 0);

            ts::return_shared(treasury);
            ts::return_shared(config);
        };

        scenario.end();
    }

    #[test, expected_failure(abort_code = bucket_v2_flash::config::EExceedMaxAmount)]
    fun test_exceed_max_amount_err() {
        // 1 M
        let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = setup(supply_limit);
        let s = &mut scenario;

        // update config params
        s.next_tx(admin());
        {
            let cap = s.take_from_sender<AdminCap>();
            let mut config = s.take_shared<GlobalConfig>();
            let treasury = s.take_shared<Treasury>();

            let fee_rate = 5; // 5bps
            let max_amount = 1_000_000 * 10_u64.pow(usdb::decimal()); // 1M
            config.set_flash_config(&cap, option::none(), fee_rate, max_amount);

            s.return_to_sender(cap);
            ts::return_shared(treasury);
            ts::return_shared(config);
        };

        s.next_tx(admin());
        {
            let mut config = s.take_shared<GlobalConfig>();
            let mut treasury = s.take_shared<Treasury>();

            let value = 2_000_000 * 10_u64.pow(usdb::decimal());
            let (usdb, receipt) = config.flash_mint(
                &mut treasury,
                &option::none(),
                value,
                s.ctx(),
            );
            assert!(burn_coin(usdb) == value);

            assert!(config.total_amount(option::none()) == value);

            let fee = float::from(value).mul(config.fee_rate(option::none())).ceil();
            config.flash_burn(
                &mut treasury,
                mint_coin(value + fee, s.ctx()),
                receipt,
            );

            assert!(config.total_amount(option::none()) == 0);

            ts::return_shared(treasury);
            ts::return_shared(config);
        };

        scenario.end();
    }

    #[test, expected_failure(abort_code = bucket_v2_flash::config::ERepaymentNotEnough)]
    fun test_repayment_not_enough_err() {
        // 1M
        let supply_limit = 1_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = setup(supply_limit);
        let s = &mut scenario;

        // update config params
        s.next_tx(admin());
        {
            let cap = s.take_from_sender<AdminCap>();
            let mut config = s.take_shared<GlobalConfig>();
            let treasury = s.take_shared<Treasury>();

            let fee_rate = 5; // 5bps
            let max_amount = 1_000_000 * 10_u64.pow(usdb::decimal()); // 1M
            config.set_flash_config(&cap, option::none(), fee_rate, max_amount);

            s.return_to_sender(cap);
            ts::return_shared(treasury);
            ts::return_shared(config);
        };

        s.next_tx(admin());
        {
            let mut config = s.take_shared<GlobalConfig>();
            let mut treasury = s.take_shared<Treasury>();

            let value = 1_000_000 * 10_u64.pow(usdb::decimal());
            let (usdb, receipt) = config.flash_mint(
                &mut treasury,
                &option::none(),
                value,
                s.ctx(),
            );
            assert!(burn_coin(usdb) == value);

            assert!(config.total_amount(option::none()) == value);

            config.flash_burn(
                &mut treasury,
                mint_coin(value, s.ctx()),
                receipt,
            );

            assert!(config.total_amount(option::none()) == 0);

            ts::return_shared(treasury);
            ts::return_shared(config);
        };

        scenario.end();
    }
}
