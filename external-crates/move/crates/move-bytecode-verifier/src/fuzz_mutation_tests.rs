// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Mutation fuzzer for the Move bytecode deserialize -> verify pipeline.
//!
//! Package publication is permissionless, so a validator/fullnode runs
//! `CompiledModule::deserialize` followed by the full bytecode verifier on
//! attacker-supplied bytes. Either step returning `Err` is fine; a *panic*
//! (index-out-of-bounds, arithmetic overflow, unwrap, stack overflow, ...) is a
//! remote crash. This test throws deterministic byte-level mutations of valid
//! modules -- plus fully random buffers -- at that pipeline and fails if any
//! input makes it panic instead of returning an error.

#![cfg(test)]

use crate::verifier::verify_module_with_config_unmetered;
use move_binary_format::file_format::{
    basic_test_module, basic_test_module_with_enum, empty_module,
};
use move_binary_format::file_format_common::VERSION_MAX;
use move_binary_format::CompiledModule;
use move_vm_config::verifier::VerifierConfig;
use std::panic::{self, AssertUnwindSafe};

/// Small deterministic xorshift PRNG so failures reproduce from the seed alone.
struct Rng(u64);
impl Rng {
    fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    fn below(&mut self, n: usize) -> usize {
        if n == 0 {
            0
        } else {
            (self.next_u64() % n as u64) as usize
        }
    }
}

fn seed_corpus() -> Vec<Vec<u8>> {
    let modules = vec![
        empty_module(),
        basic_test_module(),
        basic_test_module_with_enum(),
    ];
    modules
        .into_iter()
        .map(|m| {
            let mut bytes = vec![];
            m.serialize_with_version(VERSION_MAX, &mut bytes)
                .expect("valid module serializes");
            bytes
        })
        .collect()
}

/// Apply a handful of random byte-level mutations to `bytes`.
fn mutate(bytes: &mut Vec<u8>, rng: &mut Rng) {
    let ops = 1 + rng.below(6);
    for _ in 0..ops {
        if bytes.is_empty() {
            bytes.push(rng.next_u64() as u8);
            continue;
        }
        match rng.below(5) {
            0 => {
                // flip a bit
                let i = rng.below(bytes.len());
                bytes[i] ^= 1u8 << rng.below(8);
            }
            1 => {
                // set a random byte
                let i = rng.below(bytes.len());
                bytes[i] = rng.next_u64() as u8;
            }
            2 => {
                // insert a byte
                let i = rng.below(bytes.len() + 1);
                bytes.insert(i, rng.next_u64() as u8);
            }
            3 => {
                // delete a byte
                let i = rng.below(bytes.len());
                bytes.remove(i);
            }
            _ => {
                // truncate
                let i = rng.below(bytes.len());
                bytes.truncate(i);
            }
        }
    }
}

/// Run one candidate through deserialize -> verify, catching panics.
/// Returns Some(stage) if a panic occurred.
fn exercise(bytes: &[u8], config: &VerifierConfig) -> Option<&'static str> {
    let de = panic::catch_unwind(AssertUnwindSafe(|| {
        CompiledModule::deserialize_with_defaults(bytes)
    }));
    let module = match de {
        Err(_) => return Some("deserialize"),
        Ok(Ok(m)) => m,
        Ok(Err(_)) => return None, // clean deserialize error
    };
    let ve = panic::catch_unwind(AssertUnwindSafe(|| {
        let _ = verify_module_with_config_unmetered(config, &module);
    }));
    if ve.is_err() {
        return Some("verify");
    }
    None
}

/// Long-running fuzz campaign; run explicitly, preferably with `--release`
/// (`cargo test --release ... fuzz_deserialize_verify_no_panic -- --ignored`).
/// Release mode matches mainnet semantics: debug-only `safe_assert!`/`debug_assert!`
/// panics become `Err`, so a panic under `--release` is a real remote-crash candidate.
#[test]
#[ignore = "long fuzz campaign; run with --release"]
fn fuzz_deserialize_verify_no_panic() {
    const ITERATIONS: usize = 300_000;
    let config = VerifierConfig::default();
    let corpus = seed_corpus();
    let mut rng = Rng(0x5EED_1234_ABCD_0001);

    // Silence per-catch panic hook noise; restore afterwards.
    let prev_hook = panic::take_hook();
    panic::set_hook(Box::new(|_| {}));

    let mut failure: Option<(usize, &'static str, Vec<u8>)> = None;
    for i in 0..ITERATIONS {
        // 15% of the time use a fully random buffer, else mutate a seed.
        let mut bytes = if rng.below(100) < 15 {
            let len = rng.below(256);
            (0..len).map(|_| rng.next_u64() as u8).collect::<Vec<u8>>()
        } else {
            corpus[rng.below(corpus.len())].clone()
        };
        mutate(&mut bytes, &mut rng);

        if let Some(stage) = exercise(&bytes, &config) {
            failure = Some((i, stage, bytes));
            break;
        }
    }

    panic::set_hook(prev_hook);

    if let Some((i, stage, bytes)) = failure {
        panic!(
            "PANIC in {stage} at iteration {i} (seed=0x5EED_1234_ABCD_0001)\n\
             input ({} bytes) = {}\n",
            bytes.len(),
            hex_encode(&bytes),
        );
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{:02x}", b));
    }
    s
}
