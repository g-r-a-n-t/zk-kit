# fe-zkkit: Reusable Merkle Primitives for zk-kit

LeanIMT and Sparse Merkle Tree implemented in Fe, matching the algorithms, ABI, and optimization strategies of the Solidity reference. Both implementations share the same Foundry test suite. Across 12 benchmarks the Fe implementation uses 3-15% less gas, but the more interesting part is what the language makes possible for library design.

---

## What this makes possible

The gas benchmarks (below) use a hand-optimized bench contract for fair comparison. But the same crate also contains a reusable library (`hash.fe`, `lean_imt.fe`, `smt.fe`) that demonstrates language features that go beyond what the current toolchain offers.

### Hasher trait

Merkle tree implementations across the Ethereum ecosystem use different hash functions: Keccak, Poseidon, Pedersen. Today, adapting a Merkle library to a different hasher means forking the codebase and replacing every hash call, or paying `STATICCALL` overhead (~100 gas per call once warm, plus a one-time 2,500 cold-access surcharge, roughly 4,000-6,000 extra gas across a 32-step Merkle loop).

Fe's `Hasher` trait separates the hash function from the tree logic. The core library is audited once. Switching hashers is a drop-in replacement with zero changes to the library code. The compiler resolves which implementation to use at compile time (monomorphization), so there is no runtime dispatch cost:

```rust
pub trait Hasher {
    fn alloc_scratch() -> u256
    fn hash2_at(ptr: u256, left: u256, right: u256) -> u256
    fn hash2(left: u256, right: u256) -> u256
}

pub struct KeccakHasher {}

impl Hasher for KeccakHasher {
    fn alloc_scratch() -> u256 { alloc(64) }
    fn hash2_at(ptr: u256, left: u256, right: u256) -> u256 {
        ops::mstore(ptr, left)
        ops::mstore(ptr + 32, right)
        ops::keccak256(ptr, 64)
    }
    fn hash2(left: u256, right: u256) -> u256 {
        let ptr = alloc(64)
        KeccakHasher::hash2_at(ptr, left, right)
    }
}
```

Every library function takes `H: Hasher` as a type parameter. To switch from Keccak to Poseidon, you implement `Hasher` for a `PoseidonHasher` struct and the library code stays the same. The compiler generates specialized bytecode for each hasher.

### Const generics

Different applications need different tree depths. Today each depth requires either a hardcoded function (e.g., `uint256[32] calldata siblings`) duplicated for each depth, or dynamic arrays (`uint256[] calldata siblings`) that add runtime bounds-checking overhead and prevent the optimizer from knowing the loop bound.

Const generics let you parameterize a function over a compile-time constant. The compiler generates specialized code for each value used, so `compute_root<KeccakHasher, 32>` becomes bytecode optimized specifically for depth 32, just as if you had hardcoded `32` everywhere:

```rust
pub fn compute_root<H: Hasher, const DEPTH: usize>(
    leaf: u256,
    index: u256,
    enables: u256,
    siblings: [u256; DEPTH],  // array size known at compile time
) -> u256 {
    // ...
    let all_enabled_mask = (1 << (DEPTH as u256)) - 1
    // ...
    while i < DEPTH { ... }
}
```

The same function works for depth 8, 20, or 32. The compiler monomorphizes it, generating a separate, optimized version for each depth used. There is no runtime branching on the depth value, no dynamic array bounds checks, and the loop bound is a compile-time constant enabling further optimization.

### Inlined library imports

Shared library code today either requires `DELEGATECALL` (100 gas warm, 2,600 gas cold) or must be copy-pasted into each contract. The Solidity bench contract (190 lines) embeds all algorithm logic directly.

Fe's library (`hash.fe`, `lean_imt.fe`, `smt.fe`) lives in separate, reusable files. Any contract can call them with zero overhead. The compiler inlines everything:

```rust
let root = lean_imt::compute_root_from_proof<KeccakHasher, 32>(
    leaf, index, siblings_len, siblings)
```

The bench contract and the library produce identical bytecode.

### Generic `hash_step`

The hash-step pattern (hash `(node, sibling)` or `(sibling, node)` depending on the index bit) appears 6 times in the Solidity reference (compute, verify, update x LeanIMT, SMT, with SMT having both fast-path and slow-path copies):

Solidity (`_computeLeanIMTRoot`):
```solidity
if (isRightChild) {
    node = _hash2(sibling, node);
} else {
    node = _hash2(node, sibling);
}
```

Solidity (`updateLeanIMTRoot`), same block, duplicated with two nodes:
```solidity
if (isRightChild) {
    oldNode = _hash2(sibling, oldNode);
    newNode = _hash2(sibling, newNode);
} else {
    oldNode = _hash2(oldNode, sibling);
    newNode = _hash2(newNode, sibling);
}
```

Fe replaces all of them with one generic helper:

```rust
pub fn hash_step<H: Hasher>(
    scratch: u256, node: u256, sibling: u256, is_right_child: bool,
) -> u256 {
    if is_right_child {
        H::hash2_at(scratch, sibling, node)
    } else {
        H::hash2_at(scratch, node, sibling)
    }
}
```

Every call site becomes a single line:
```fe
node = hash_step<H>(scratch, node, siblings[i], (idx & 1) == 1)
```

The `<H: Hasher>` bound means this works with any hash function. The compiler inlines it at every call site. The generated bytecode is identical to writing the if/else by hand.

### Configurable ABI selectors

Backend library contracts, like a deployed Poseidon hasher used by MACI, Semaphore, or other on-chain protocols, typically expose a single function. The mandatory 4-byte ABI selector is pure overhead.

Fe's `Abi` trait makes the selector format a type parameter:

```rust
pub trait Abi {
    type Selector          // u32 for Solidity, u8 or () for custom ABIs
    const SELECTOR_SIZE: u256   // 4 for Solidity, 1 or 0 for custom
    fn selector_from_prefix(_: u256) -> Self::Selector
    // ...
}
```

The default `Sol` implementation uses a 4-byte `u32` selector, so Fe contracts are fully compatible with the existing ecosystem out of the box. But a contract author can implement a custom `Abi` with a 1-byte selector, or no selector at all, and the compiler generates the matching dispatch code.

Where this matters today: these single-function library contracts can use a zero-selector ABI (raw calldata = just the inputs), saving 4 bytes of calldata per call. At 16 gas per non-zero calldata byte, that is up to 64 gas saved on every cross-contract hash invocation.

Where this matters in the future: as infrastructure matures (JavaScript libraries, wallets, indexers, block explorers) to support alternative message-passing formats, the savings extend to user-facing contracts as well. Nearly all deployed contracts today have fewer than 256 functions. 1 byte is enough to express every selector. A 1-byte selector ABI would save 3 bytes (up to 48 gas) per call, with no loss of expressiveness.

---

## Zero-cost abstractions

The Fe library uses traits (`Hasher`) and const generics (`DEPTH`) throughout for clean, reusable code. These abstractions have zero gas overhead: the Sonatina backend monomorphizes every trait bound and const-generic parameter at compile time, producing the same bytecode as hand-inlined code. There is no dynamic dispatch, no vtable lookup, and no runtime branching on generic parameters.

---

## Benchmark results

### LeanIMT (variable-depth incremental Merkle tree)

| Operation | fe-zkkit | Baseline | Saved |
|-----------|-------:|-------:|------:|
| computeRoot (32 siblings) | 14,105 | 16,564 | -14.8% |
| computeRoot (typical) | 9,788 | 10,640 | -8.0% |
| verify (32 siblings) | 14,190 | 16,563 | -14.3% |
| verify (typical) | 9,869 | 10,639 | -7.2% |
| updateRoot (32 siblings) | 16,538 | 18,425 | -10.2% |
| updateRoot (typical) | 10,494 | 11,023 | -4.8% |

### Sparse Merkle Tree (fixed-depth with proof compression)

| Operation | fe-zkkit | Baseline | Saved |
|-----------|-------:|-------:|------:|
| computeRoot (all enabled) | 14,241 | 16,558 | -14.0% |
| computeRoot (typical) | 17,264 | 18,981 | -9.0% |
| verify (all enabled) | 14,301 | 16,621 | -14.0% |
| verify (typical) | 17,369 | 19,069 | -8.9% |
| updateRoot (all enabled) | 17,042 | 18,546 | -8.1% |
| updateRoot (typical) | 20,339 | 20,954 | -2.9% |

Both implementations use the same algorithm, hash function (Keccak), ABI, and closely matched optimization strategies (scratch memory reuse, calldata-direct reads, precomputed zero table, interleaved update loops). This setup is intended to minimize non-compiler differences, so observed gas deltas are primarily due to compiler/codegen behavior.

Fe (Sonatina backend, OPT_LEVEL=2) vs optimized Solidity (`solc --optimize`, 200 runs).
48 tests, 1024 fuzz runs each.

### Benchmark vectors

- LeanIMT typical: `siblingsLen=7`, `index=11`
- LeanIMT 32 siblings: `siblingsLen=32`, `index=0x1234_5678`
- SMT typical: `index=0x1234_5678`, `enables` has bits `{0,3,5,12,31}` set (5 provided siblings)
- SMT all-enabled: `index=0x1234_5678`, `enables=0xffffffff` (32 provided siblings)

---

## Reproducing

```bash
cd fe-zkkit/bench
rm -rf out/fe
FE_SONA_OPT_LEVEL=2 forge test --ffi --offline -vvv
```

48 tests: 12 gas benchmarks (Fe Sonatina) + 12 gas benchmarks (Fe Yul) + 12 gas benchmarks (Solidity) + 8 fuzz tests (1024 runs each) + 4 deterministic correctness tests.

## Source

- Fe library: `fe-zkkit/zkkit_merkle/src/` (`hash.fe`, `lean_imt.fe`, `smt.fe`)
- Fe bench contract: `fe-zkkit/zkkit_merkle/src/bench_contract.fe`
- Solidity reference: `fe-zkkit/bench/src/SolidityMerkleBench.sol`
- Test harness: `fe-zkkit/bench/test/ZkKitMerkleBench.t.sol`
