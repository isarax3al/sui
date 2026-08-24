#[test_only]
/// Adversarial conservation tests: attempt to extract value from the PSM via
/// round-trips and edge decimals. Any assertion failure here is a value-creation bug.
module bucket_v2_psm::adversarial_conservation_tests {
    use bucket_v2_framework::float;
    use bucket_v2_oracle::result as price_result;
    use bucket_v2_psm::pool::{Self, Pool};
    use bucket_v2_psm::bucket_v2_psm_tests::{Self as psm, USDC};
    use bucket_v2_usd::usdb::{Self, USDB, Treasury};
    use sui::{coin, test_scenario::{Self as ts}};

    const USDC_DECIMALS: u8 = 6;

    fun seed_pool(s: &mut sui::test_scenario::Scenario, who: address, amt: u64) {
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

    /// Round-trip: swap_in X asset -> USDB -> swap_out -> asset'. Assert the user
    /// never ends up with MORE asset than they started (value cannot be created),
    /// even with ZERO fees. Stress the flooring with tiny/odd amounts.
    #[test]
    fun test_roundtrip_never_profits() {
        let supply_limit = 1_000_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = psm::setup(supply_limit);
        let s = &mut scenario;
        // zero fees => best possible case for the attacker
        psm::create_pool<USDC>(s, USDC_DECIMALS, 0, 0);

        // seed liquidity so swap_out has funds
        seed_pool(s, @0xA11CE, 1_000_000 * 10u64.pow(USDC_DECIMALS));

        let user = @0xBAD;
        let amounts = vector[1u64, 2, 3, 7, 999, 1000, 1001, 123457, 1_000_007];
        amounts.do!(|amt| {
            s.next_tx(user);
            let mut pool = s.take_shared<Pool<USDC>>();
            let mut treasury = s.take_shared<Treasury>();
            let price = price_result::new_for_testing<USDC>(float::from(1));

            let asset_in = coin::mint_for_testing<USDC>(amt, s.ctx());
            let usdb = pool.swap_in(&mut treasury, &price, asset_in, &option::none(), s.ctx());
            let asset_back = pool.swap_out(&mut treasury, &price, usdb, &option::none(), s.ctx());
            let back = asset_back.burn_for_testing();
            // CONSERVATION: cannot get back more than put in
            assert!(back <= amt, 9001);
            ts::return_shared(treasury);
            ts::return_shared(pool);
        });
        scenario.end();
    }

    /// Invariant: pool asset balance must back its tracked usdb_supply (>= 1:1 at
    /// equal decimals). If minting ever outpaces backing, this breaks.
    #[test]
    fun test_pool_backing_invariant() {
        let supply_limit = 1_000_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = psm::setup(supply_limit);
        let s = &mut scenario;
        psm::create_pool<USDC>(s, USDC_DECIMALS, 10, 20);

        seed_pool(s, @0x1, 500_000 * 10u64.pow(USDC_DECIMALS));
        seed_pool(s, @0x2, 300_007);

        s.next_tx(@0x3);
        let pool = s.take_shared<Pool<USDC>>();
        assert!(pool.balance() >= pool.usdb_supply(), 9002);
        ts::return_shared(pool);
        scenario.end();
    }
}
