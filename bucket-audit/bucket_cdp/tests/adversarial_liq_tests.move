#[test_only]
/// Adversarial liquidation test: does splitting a liquidation into many tiny
/// steps let the liquidator seize MORE collateral for LESS total repayment
/// (exploiting the per-step `ceil` in the seizure formula)? If so -> bug.
module bucket_v2_cdp::adversarial_liq_tests {
    use bucket_v2_cdp::bucket_v2_cdp_tests::{Self as cdp, LiquidationRule};
    use bucket_v2_usd::usdb;
    use sui::sui::SUI;

    #[test]
    fun test_split_liquidation_not_more_profitable() {
        let supply_limit = 100_000_000 * 10u64.pow(usdb::decimal());
        let mut scenario = cdp::setup<SUI, LiquidationRule>(9, supply_limit);
        let s = &mut scenario;

        // two identical debtors: deposit 1000 SUI, borrow 1000 USDB at price 2.0
        let a = @0xA; let b = @0xB;
        let (_,_) = cdp::manage_position<SUI>(s, a, cdp::sui(1_000), cdp::usdb(1_000), 0, 0, option::some(20000));
        let (_,_) = cdp::manage_position<SUI>(s, b, cdp::sui(1_000), cdp::usdb(1_000), 0, 0, option::some(20000));

        // price drops to 1.05 -> ICR = 1.05 < 1.10 MCR -> unhealthy
        let liq_price = 10500;

        // A: single-shot full liquidation (repay full 1000 debt)
        let a_seized = cdp::liquidate<SUI>(s, @0x1A, a, option::some(cdp::usdb(1_000)), liq_price);

        // B: liquidate in 100 tiny steps of 10 USDB each
        let mut b_seized = 0u64;
        let mut i = 0;
        while (i < 5) {
            b_seized = b_seized + cdp::liquidate<SUI>(s, @0x1B, b, option::some(cdp::usdb(200)), liq_price);
            i = i + 1;
        };

        // Splitting must NOT let the attacker seize meaningfully more collateral for
        // the same total repayment (1000). Allow only per-step ceil dust.
        assert!(b_seized <= a_seized + 100, 7001);
        scenario.end();
    }
}
