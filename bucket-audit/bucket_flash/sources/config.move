module bucket_v2_flash::config {
    use bucket_v2_flash::{events, memo, version::package_version, witness::witness};
    use bucket_v2_framework::{account::AccountRequest, float::{Self, Float}};
    use bucket_v2_usd::{admin::AdminCap, usdb::{USDB, Treasury}};
    use sui::{coin::Coin, vec_map::{Self, VecMap}};

    // === Errors ===

    const EExceedMaxAmount: u64 = 401;
    fun err_exceed_max_amount() { abort EExceedMaxAmount }

    const ERepaymentNotEnough: u64 = 402;
    fun err_repayment_not_enough() { abort ERepaymentNotEnough }

    // === Objects ===

    public struct GlobalConfig has key {
        id: UID,
        default_config: Config,
        partner_configs: VecMap<address, Config>,
    }

    // === Structs ===

    public struct Config has copy, drop, store {
        fee_rate: Float,
        max_amount: u64,
        total_amount: u64,
    }

    // Hot-potato
    public struct FlashMintReceipt {
        partner: Option<address>,
        mint_amount: u64,
        fee_amount: u64,
    }

    // === Init ===

    fun init(ctx: &mut TxContext) {
        let config = GlobalConfig {
            id: object::new(ctx),
            default_config: Config {
                fee_rate: float::from_bps(0),
                max_amount: 0,
                total_amount: 0,
            },
            partner_configs: vec_map::empty(),
        };

        transfer::share_object(config);
    }

    // === Admin Functions ===

    public fun set_flash_config(
        self: &mut GlobalConfig,
        _: &AdminCap,
        partner: Option<address>,
        fee_rate_bps: u64,
        max_amount: u64,
    ) {
        if (partner.is_some()) {
            let partner_address = partner.borrow();
            if (self.partner_configs.contains(partner_address)) {
                let config = &mut self.partner_configs[partner_address];
                config.fee_rate = float::from_bps(fee_rate_bps);
                config.max_amount = max_amount;
            } else {
                self
                    .partner_configs
                    .insert(
                        *partner_address,
                        Config {
                            fee_rate: float::from_bps(fee_rate_bps),
                            max_amount,
                            total_amount: 0,
                        },
                    );
            }
        } else {
            let config = &mut self.default_config;
            config.fee_rate = float::from_bps(fee_rate_bps);
            config.max_amount = max_amount;
        };

        events::emit_update_flash_mint_config(
            object::id(self),
            partner,
            fee_rate_bps,
            max_amount,
        );
    }

    // === Public Functions ===

    public fun flash_mint(
        self: &mut GlobalConfig,
        treasury: &mut Treasury,
        partner: &Option<AccountRequest>,
        value: u64,
        ctx: &mut TxContext,
    ): (Coin<USDB>, FlashMintReceipt) {
        let config = if (partner.is_some()) {
            &mut self.partner_configs[&partner.borrow().address()]
        } else {
            &mut self.default_config
        };
        config.total_amount = config.total_amount + value;

        // check total amount and update
        if (config.total_amount > config.max_amount) {
            err_exceed_max_amount();
        };

        let output = treasury.mint(
            witness(),
            package_version(),
            value,
            ctx,
        );
        let fee_amount = float::from(value).mul(config.fee_rate).ceil();
        let partner = partner.map_ref!(|_partner| _partner.address());
        let receipt = FlashMintReceipt {
            partner,
            mint_amount: value,
            fee_amount,
        };

        events::emit_flash_mint(partner, value, fee_amount);

        (output, receipt)
    }

    public fun flash_burn(
        self: &mut GlobalConfig,
        treasury: &mut Treasury,
        mut repayment: Coin<USDB>,
        receipt: FlashMintReceipt,
    ) {
        let FlashMintReceipt {
            partner: partner,
            mint_amount,
            fee_amount,
        } = receipt;

        let config = if (partner.is_some()) {
            &mut self.partner_configs[partner.borrow()]
        } else {
            &mut self.default_config
        };

        if (repayment.value() != mint_amount + fee_amount) err_repayment_not_enough();

        config.total_amount = config.total_amount - mint_amount;
        let fee_bal = repayment.balance_mut().split(fee_amount);

        treasury.burn(
            witness(),
            package_version(),
            repayment,
        );
        treasury.collect(witness(), memo::flash_mint(), fee_bal);
    }

    // === View Functions ===

    public fun config(self: &GlobalConfig, partner_opt: Option<address>): Config {
        if (partner_opt.is_some()) self.partner_configs[partner_opt.borrow()]
        else self.default_config
    }

    public fun fee_rate(self: &GlobalConfig, partner_opt: Option<address>): Float {
        self.config(partner_opt).fee_rate
    }

    public fun max_amount(self: &GlobalConfig, partner_opt: Option<address>): u64 {
        self.config(partner_opt).max_amount
    }

    public fun total_amount(self: &GlobalConfig, partner_opt: Option<address>): u64 {
        self.config(partner_opt).total_amount
    }

    public fun mint_amount(receipt: &FlashMintReceipt): u64 {
        receipt.mint_amount
    }

    public fun fee_amount(receipt: &FlashMintReceipt): u64 {
        receipt.fee_amount
    }

    // === Test-Only Functions ===

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }
}
