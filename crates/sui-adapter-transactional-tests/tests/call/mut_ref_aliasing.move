// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//# init --addresses ex=0x0 --accounts A

// Regression test: the new VM (execution v4 / protocol 118) must uphold Move's
// guarantee that two `&mut` references passed to a single Move call are
// exclusive (non-aliasing). Passing the same input object (or the same command
// result) as two `&mut` arguments must be rejected.
//
// The classic executor rejects this at the PTB layer with InvalidValueUsage
// ("mutable borrowing requires unique usage"). The static executor rejects it
// in its memory-safety pass with InvalidReferenceArgument (the regex borrow
// graph detects that the two same-location borrows conflict). Both reject; this
// test pins that the static executor does not regress into accepting aliasing.

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

    // If the two references ever aliased, `a.v` would become 2 and this would
    // abort with code 42. The call must instead be rejected before execution.
    public fun break_exclusivity(a: &mut Box, b: &mut Box) {
        a.v = 1;
        b.v = 2;
        assert!(a.v == 1, 42);
    }

    public fun found(c: Coin<SUI>, ctx: &mut TxContext) {
        transfer::share_object(Vault { id: object::new(ctx), funds: coin::into_balance(c) })
    }

    // Pays out the combined value of two mutable "receipt" coins, relying on
    // Move's `&mut` exclusivity that `r1` and `r2` are distinct. If aliasing
    // were possible, presenting one coin as both would drain 2x from the vault.
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

//# view-object 2,0

// Pass the same object as both `&mut` arguments -- must be rejected
// (InvalidReferenceArgument), never executed.
//# programmable --sender A --inputs object(2,0)
//> ex::alias::break_exclusivity(Input(0), Input(0))

// Fund a vault, then attempt to present the same command result as both `&mut`
// receipts -- must also be rejected, leaving the vault untouched.
//# programmable --sender A --inputs 1000000000
//> 0: SplitCoins(Gas, [Input(0)]);
//> 1: ex::alias::found(Result(0))

//# view-object 5,0

//# programmable --sender A --inputs 100 @A object(5,0)
//> 0: SplitCoins(Gas, [Input(0)]);
//> 1: ex::alias::claim(Input(2), Result(0), Result(0));
//> 2: TransferObjects([Result(1)], Input(1))

// Vault funds are unchanged: the aliased-`&mut` claim was rejected.
//# view-object 5,0
