# On-chain verification of Bucket V2 PriceAggregator weights (Sui mainnet)

Read live via SDK `AGGREGATOR_OBJS` + gRPC `getObject`. **All aggregators are single-source.**

| coin | aggregator objectId | threshold | tolerance% | #sources | source (weight) |
|---|---|---|---|---|---|
| SUI | `0x795e888b…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| BTC | `0xe2d05d53…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| WAL | `0x88ba3413…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| XBTC | `0x678e7a51…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| USDC | `0x4b612d4d…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| USDT | `0x75f29f24…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| HASUI | `0x8201e813…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| CERT | `0x16b7c7e5…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| AFSUI | `0xd9768781…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| SCA | `0x28672bb8…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| BUCK | `0xe7683cdd…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| DEEP | `0x64585d0a…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| ETH | `0x635141bf…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| SCALLOP_SUI | `0xd248f5ad…` | 1 | 1 | 1 | scoin_rule::SCoinRule(1) |
| SCALLOP_USDC | `0x0b43266f…` | 1 | 1 | 1 | scoin_rule::SCoinRule(1) |
| SCALLOP_SB_USDT | `0xf64553ec…` | 1 | 1 | 1 | scoin_rule::SCoinRule(1) |
| SCALLOP_WAL | `0x95e56c1c…` | 1 | 1 | 1 | scoin_rule::SCoinRule(1) |
| SCALLOP_DEEP | `0x138d33ea…` | 1 | 1 | 1 | scoin_rule::SCoinRule(1) |
| SCALLOP_SB_ETH | `0xc846dc6b…` | 1 | 1 | 1 | scoin_rule::SCoinRule(1) |
| SCALLOP_SCA | `0xc16c6913…` | 1 | 1 | 1 | scoin_rule::SCoinRule(1) |
| UP_USD | `0x5e869f79…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| SUI> | `0xd1ae834e…` | 1 | 1 | 1 | gcoin_rule::GCoinRule(1) |
| UP_USD> | `0x10de87b3…` | 1 | 1 | 1 | gcoin_rule::GCoinRule(1) |
| BFBTC | `0xe93f95ca…` | 1 | 1 | 1 | bfbtc_rule::BfBtcRule(1) |
| WBTC | `0xd812f15d…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| XAUM | `0x7d9f757f…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |
| USDSUI | `0xbe2b1f6b…` | 1 | 1 | 1 | pyth_rule::PythRule(1) |

**Total: 27 aggregators, every one single-source (weight 1, threshold 1). The mean-vs-median outlier-filter defect is not triggerable on the current deployment.**
