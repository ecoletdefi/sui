// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// This module provides functionality for generating secure randomness.
module sui::random {
    use std::bcs;
    use std::option;
    use std::option::Option;
    use std::vector;
    use sui::dynamic_field;
    use sui::address::to_bytes;
    use sui::hmac::hmac_sha3_256;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext, fresh_object_address};
    use sui::versioned::{Self, Versioned};

    // Sender is not @0x0 the system address.
    const ENotSystemAddress: u64 = 0;
    const EWrongInnerVersion: u64 = 1;
    const EInvalidRandomnessUpdate: u64 = 2;
    const EInvalidRange: u64 = 3;

    const CURRENT_VERSION: u64 = 1;
    const RAND_OUTPUT_LEN: u16 = 32;

    ////////////////////////////////////
    /// Global randomness state.
    ///

    /// Singleton shared object which stores the global randomness state.
    /// The actual state is stored in a versioned inner field.
    struct Random has key {
        id: UID,
        // The inner object must never be accessed outside this module as it could be used for accessing global
        // randomness via deserialization of RandomInner.
        inner: Versioned,
    }

    struct RandomInner has store {
        version: u64,
        epoch: u64,
        randomness_round: u64,
        random_bytes: vector<u8>,
    }

    #[allow(unused_function)]
    /// Create and share the Random object. This function is called exactly once, when
    /// the Random object is first created.
    /// Can only be called by genesis or change_epoch transactions.
    fun create(ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == @0x0, ENotSystemAddress);

        let version = CURRENT_VERSION;

        let inner = RandomInner {
            version,
            epoch: tx_context::epoch(ctx),
            randomness_round: 0,
            random_bytes: vector[],
        };

        let self = Random {
            id: object::randomness_state(),
            inner: versioned::create(version, inner, ctx),
        };
        transfer::share_object(self);
    }

    #[test_only]
    public fun create_for_testing(ctx: &mut TxContext) {
        create(ctx);
    }

    fun load_inner_mut(
        self: &mut Random,
    ): &mut RandomInner {
        let version = versioned::version(&self.inner);

        // Replace this with a lazy update function when we add a new version of the inner object.
        assert!(version == CURRENT_VERSION, EWrongInnerVersion);
        let inner: &mut RandomInner = versioned::load_value_mut(&mut self.inner);
        assert!(inner.version == version, EWrongInnerVersion);
        inner
    }

    fun load_inner(
        self: &Random,
    ): &RandomInner {
        let version = versioned::version(&self.inner);

        // Replace this with a lazy update function when we add a new version of the inner object.
        assert!(version == CURRENT_VERSION, EWrongInnerVersion);
        let inner: &RandomInner = versioned::load_value(&self.inner);
        assert!(inner.version == version, EWrongInnerVersion);
        inner
    }

    #[allow(unused_function)]
    /// Record new randomness. Called when executing the RandomnessStateUpdate system
    /// transaction.
    fun update_randomness_state(
        self: &mut Random,
        // TODO: rounds are increasing monotonically also betweeen epochs.
        // TODO: need to guarantee that after EoP/last relevant tx, we generate 2 more rounds of randomness.
        new_round: u64,
        new_bytes: vector<u8>,
        ctx: &TxContext,
    ) {
        // Validator will make a special system call with sender set as 0x0.
        assert!(tx_context::sender(ctx) == @0x0, ENotSystemAddress);

        // Randomness should only be incremented.
        let epoch = tx_context::epoch(ctx);
        let inner = load_inner_mut(self);
        assert!(
            (epoch == inner.epoch + 1 && inner.randomness_round == 0) ||
                (new_round == inner.randomness_round + 1),
            EInvalidRandomnessUpdate
        );

        inner.epoch = tx_context::epoch(ctx);
        inner.randomness_round = new_round;
        inner.random_bytes = new_bytes;

        // TODO: Update also the RandomRounds object (with add_round).
    }

    #[test_only]
    public fun update_randomness_state_for_testing(
        self: &mut Random,
        new_round: u64,
        new_bytes: vector<u8>,
        ctx: &TxContext,
    ) {
        update_randomness_state(self, new_round, new_bytes, ctx);
    }


    ////////////////////////////////////
    /// RandomRounds store the last X random values.
    ///
    // TODO: better name?
    // TODO: create as a singleton.

    /// Container for historical randomness values.
    struct RandomRounds has key {
        id: UID,
        max_size: u64,
        oldest_round: u64,
        latest_round: u64,
        // The actual randomness must never be accessed outside this module as it could be used for accessing global
        // randomness via bcs::to_bytes(). We use dynamic fields to store the randomness values.
    }

    fun create_random_rounds() {
        transfer::share_object(RandomRounds {
            id: object::randomness_state(), // TODO: update
            max_size: 1,
            oldest_round: 1,
            latest_round: 0,
        });
    }

    #[test_only]
    public fun create_random_rounds_for_testing(ctx: &mut TxContext) {
        create(ctx);
    }

    // The entry function for Sui. This function also updates the max_size if needed.
    fun add_random_round(rr:&mut RandomRounds, new_max_size: u64, round: u64, value: vector<u8>) {
        assert!(new_max_size > 0, 1);
        assert!(round == rr.latest_round + 1, 2);
        rr.max_size = new_max_size;
        rr.latest_round = round;
        while (rr.max_size < rr.latest_round - rr.oldest_round + 1) {
            dynamic_field::remove<u64, vector<u8>>(&mut rr.id, rr.oldest_round);
            rr.oldest_round = rr.oldest_round + 1;
        };
        dynamic_field::add(&mut rr.id, round, value);
    }

    /// Set of inputs that can be used to create a RandomGenerator
    // TODO: better name?
    struct RandomnessRequest has store {
        round: u64,
        seed: vector<u8>,
    }

    public fun create_randomness_request(rr: &RandomRounds, ctx: &mut TxContext): RandomnessRequest {
        RandomnessRequest {
            round: rr.latest_round + 2, // next round that is safe when the current transaction is executed.
            seed: to_bytes(fresh_object_address(ctx)), // globally unique (thuogh predictable).
        }
    }

    /// Deterministic derivation of the seed for the given round.
    public fun fulfill_and_create_generator(req: &RandomnessRequest, rr: &RandomRounds): RandomGenerator {
        assert!(req.round >= rr.oldest_round && req.round <= rr.latest_round, 0); // TODO: better error
        let randomness = dynamic_field::borrow(&rr.id, req.round);
        let seed = hmac_sha3_256(randomness, &req.seed);
        RandomGenerator {
            seed,
            counter: 0,
            buffer: vector::empty(),
        }
    }

    public fun is_available(req: &RandomnessRequest, rr: &RandomRounds): bool {
        req.round >= rr.oldest_round && req.round <= rr.latest_round
    }

    public fun is_too_old(req: &RandomnessRequest, rr: &RandomRounds): bool {
        req.round < rr.oldest_round
    }

    public fun required_round(req: &RandomnessRequest): u64 {
        req.round
    }

    // TODO: Decide on how dapps could know when to call fulfill_and_create_generator.
    // Options:
    //  1. [Polling, Node APIs] tx1 calls create_randomness_request which returns the required randomness round either
    //     as an output or as an event (or read directly from the chain)
    //     -> dapp reads the value of RandomRounds from FN until the relevant randomness is available
    //     -> sends tx2 that calls fulfill_and_create_generator
    //  2. [Events] tx1 calls create_randomness_request which returns the required randomness round (as before)
    //     -> waits for emitted event "round X is available" (by the random module)
    //     -> sends tx2 that calls fulfill_and_create_generator
    //  3. [Deferred execution for tx2] tx1 calls create_randomness_request
    //     -> waits for tx1 finalization
    //     -> sends tx2 that calls fulfill_and_create_generator with the next version of Random; this guarantees that
    //     once tx2 is executed, the required randomness round is available.
    // I think that 2 is the simplest to start with; if there is a need, one could implement a public "pusher service"
    // for tx2.

    ////////////////////////////////////
    /// Unique randomness generator per seed.
    ///

    struct RandomGenerator has drop {
        seed: vector<u8>,
        counter: u16,
        buffer: vector<u8>,
    }

    // Get the next block of random bytes.
    fun derive_next_block(g: &mut RandomGenerator): vector<u8> {
        g.counter = g.counter + 1;
        hmac_sha3_256(&g.seed, &bcs::to_bytes(&g.counter))
    }

    // Fill the generator's buffer with 32 random bytes.
    fun fill_buffer(g: &mut RandomGenerator) {
        let next_block = derive_next_block(g);
        vector::append(&mut g.buffer, next_block);
    }

    /// Generate n random bytes.
    public fun bytes(g: &mut RandomGenerator, num_of_bytes: u16): vector<u8> {
        let result = vector::empty();
        // Append RAND_OUTPUT_LEN size buffers directly without going through the generator's buffer.
        let num_of_blocks = num_of_bytes / RAND_OUTPUT_LEN;
        while (num_of_blocks > 0) {
            vector::append(&mut result, derive_next_block(g));
            num_of_blocks = num_of_blocks - 1;
        };
        // Take remaining bytes from the generator's buffer.
        if (vector::length(&g.buffer) < ((num_of_bytes as u64) - vector::length(&result))) {
            fill_buffer(g);
        };
        while (vector::length(&result) < (num_of_bytes as u64)) {
            vector::push_back(&mut result, vector::pop_back(&mut g.buffer));
        };
        result
    }

    // Helper function that extracts the given number of bytes from the random generator and returns it as u256.
    // Assumes that the caller has already checked that num_of_bytes is valid.
    fun u256_from_bytes(g: &mut RandomGenerator, num_of_bytes: u8): u256 {
        if (vector::length(&g.buffer) < (num_of_bytes as u64)) {
            fill_buffer(g);
        };
        let result: u256 = 0;
        let i = 0;
        while (i < num_of_bytes) {
            let byte = vector::pop_back(&mut g.buffer);
            result = (result << 8) + (byte as u256);
            i = i + 1;
        };
        result
    }

    /// Generate a u256.
    public fun generate_u256(g: &mut RandomGenerator): u256 {
        u256_from_bytes(g, 32)
    }

    /// Generate a u128.
    public fun generate_u128(g: &mut RandomGenerator): u128 {
        (u256_from_bytes(g, 16) as u128)
    }

    /// Generate a u64.
    public fun generate_u64(g: &mut RandomGenerator): u64 {
        (u256_from_bytes(g, 8) as u64)
    }

    /// Generate a u32.
    public fun generate_u32(g: &mut RandomGenerator): u32 {
        (u256_from_bytes(g, 4) as u32)
    }

    /// Generate a u16.
    public fun generate_u16(g: &mut RandomGenerator): u16 {
        (u256_from_bytes(g, 2) as u16)
    }

    /// Generate a u8.
    public fun generate_u8(g: &mut RandomGenerator): u8 {
        (u256_from_bytes(g, 1) as u8)
    }

    // Helper function to generate a random u128 in [min, max] using a random number with num_of_bytes bytes.
    // Assumes that the caller verified the inputs, and uses num_of_bytes to control the bias.
    fun u128_in_range(g: &mut RandomGenerator, min: u128, max: u128, num_of_bytes: u8): u128 {
        assert!(min < max, EInvalidRange);
        let diff = ((max - min) as u256) + 1;
        let rand = u256_from_bytes(g, num_of_bytes);
        min + ((rand % diff) as u128)
    }

    /// Generate a random u128 in [min, max] (with a bias of 2^{-64}).
    public fun generate_u128_in_range(g: &mut RandomGenerator, min: u128, max: u128): u128 {
        u128_in_range(g, min, max, 24)
    }

    //// Generate a random u64 in [min, max] (with a bias of 2^{-64}).
    public fun generate_u64_in_range(g: &mut RandomGenerator, min: u64, max: u64): u64 {
        (u128_in_range(g, (min as u128), (max as u128), 16) as u64)
    }

    /// Generate a random u32 in [min, max] (with a bias of 2^{-64}).
    public fun generate_u32_in_range(g: &mut RandomGenerator, min: u32, max: u32): u32 {
        (u128_in_range(g, (min as u128), (max as u128), 12) as u32)
    }

    /// Generate a random u16 in [min, max] (with a bias of 2^{-64}).
    public fun generate_u16_in_range(g: &mut RandomGenerator, min: u16, max: u16): u16 {
        (u128_in_range(g, (min as u128), (max as u128), 10) as u16)
    }

    /// Generate a random u8 in [min, max] (with a bias of 2^{-64}).
    public fun generate_u8_in_range(g: &mut RandomGenerator, min: u8, max: u8): u8 {
        (u128_in_range(g, (min as u128), (max as u128), 9) as u8)
    }

    #[test_only]
    public fun generator_seed(r: &RandomGenerator): &vector<u8> {
        &r.seed
    }

    #[test_only]
    public fun generator_counter(r: &RandomGenerator): u16 {
        r.counter
    }

    #[test_only]
    public fun generator_buffer(r: &RandomGenerator): &vector<u8> {
        &r.buffer
    }

}
