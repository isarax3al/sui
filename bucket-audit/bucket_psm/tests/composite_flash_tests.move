#[test_only]
/// Composite/cross-module PoC: flash-mint USDB, route it through the PSM
/// (swap_out -> asset -> swap_in -> USDB), then repay the flash — in one tx.
/// Proves there is NO atomic arbitrage: even with ZERO PSM fees and a 1:1
/// (equal-decimals) pool, the round-trip returns at most the flash principal,
/// so the attacker cannot even cover the flash fee and ends at a net loss.
module bucket_v2_psm::composite_flash_tests {
    use bucket_v2_flash::config::{Self as flash, GlobalConfig};
    use bucket_v2_flash::witness::BucketV2Flash;
    use bucket_v2_framework::float;
    use bucket_v2_oracle::result as price_result;
    use bucket_v2_psm::pool::{Self, Pool};
    use bucket_v2_psm::bucket_v2_psm_tests::{Self as psm, USDC};
    use bucket_v2_usd::admin::AdminCap;
    use bucket_v2_usd::usdb::{Self, USDB, Treasury};
    use bucket_v2_usd::bucket_v2_usd_tests::admin;
    use sui::{coin, test_scenario::{Self as ts, Scenario}};

    const USDC_DECIMALS: u8 = 6;

    fun seed_pool(s: &mut Scenario, who: address, amt: u64) {
        s.next_tx(who);
        let mut pool = s.take_shared<Pool<USDC>>();
        let mut treasury = s.take_shared<Treasury>();
        let price = price_result::new_for_testing<USDC>(float::from(1));
        let asset_in = coin::mint_for_testing<USDC>(amt, s.ctx());
        let usdb = pool.swap_in(&mut treasury, &price, asset_in, &option::none(), s.ctx());
        usdb.burn_for_testing();
        ts::return_shared(treasury);
        ts::return_shared(pool);
    }

    #[test]
    fun test_flash_psm_roundtrip_no_arbitrage() {
        let supply_limit = 1_000_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = psm::setup(supply_limit); // registers BucketV2PSM in treasury
        let s = &mut scenario;

        // Register the flash module in the same treasury + init its config.
        s.next_tx(admin());
        {
            let cap = s.take_from_sender<AdminCap>();
            let mut treasury = s.take_shared<Treasury>();
            treasury.add_version<BucketV2Flash>(&cap, 1);
            treasury.set_supply_limit<BucketV2Flash>(&cap, supply_limit);
            ts::return_shared(treasury);
            s.return_to_sender(cap);
        };
        flash::init_for_testing(s.ctx());
        s.next_tx(admin());
        {
            let cap = s.take_from_sender<AdminCap>();
            let mut config = s.take_shared<GlobalConfig>();
            // 5 bps flash fee, huge cap
            config.set_flash_config(&cap, option::none(), 5, supply_limit);
            ts::return_shared(config);
            s.return_to_sender(cap);
        };

        // PSM pool with ZERO swap fees (best possible case for the attacker), 1:1 decimals.
        psm::create_pool<USDC>(s, USDC_DECIMALS, 0, 0);
        seed_pool(s, @0xA11CE, 1_000_000 * 10u64.pow(USDC_DECIMALS));

        // ===== the composite attack, single tx =====
        let attacker = @0xBAD;
        let b = 100_000 * 10u64.pow(usdb::decimal());
        s.next_tx(attacker);
        let mut config = s.take_shared<GlobalConfig>();
        let mut pool = s.take_shared<Pool<USDC>>();
        let mut treasury = s.take_shared<Treasury>();
        let price = price_result::new_for_testing<USDC>(float::from(1));

        // 1) flash-mint B USDB (hot-potato receipt requires B + fee back)
        let (usdb_flash, receipt) = config.flash_mint(&mut treasury, &option::none(), b, s.ctx());
        let fee = receipt.fee_amount();
        assert!(fee > 0, 3000);

        // 2) route it through the PSM and back
        let asset = pool.swap_out(&mut treasury, &price, usdb_flash, &option::none(), s.ctx());
        let usdb_back = pool.swap_in(&mut treasury, &price, asset, &option::none(), s.ctx());
        let r = usdb_back.value();

        // NO ARBITRAGE: round-trip never exceeds the principal ...
        assert!(r <= b, 3001);
        // ... and cannot even cover principal + flash fee -> a strict shortfall exists.
        assert!(r < b + fee, 3002);

        // 3) repay the flash: the attacker MUST inject their own funds to close it.
        let shortfall = (b + fee) - r;
        assert!(shortfall > 0, 3003);                 // proven net loss = they add money
        let mut repay = usdb_back;
        repay.join(coin::mint_for_testing<USDB>(shortfall, s.ctx()));
        // repay.value() == b + fee exactly, as flash_burn requires
        config.flash_burn(&mut treasury, repay, receipt);

        ts::return_shared(config);
        ts::return_shared(pool);
        ts::return_shared(treasury);
        scenario.end();
    }
}
