// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SolidityMerkleBench} from "../src/SolidityMerkleBench.sol";

interface Vm {
    function ffi(string[] calldata) external returns (bytes memory);
    function readFile(string calldata path) external returns (string memory);
    function pauseGasMetering() external;
    function resumeGasMetering() external;
    function envOr(string calldata name, uint256 defaultValue) external returns (uint256);
}

interface IFeZkKitMerkleBench {
    function computeLeanIMTRoot(uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] calldata siblings)
        external
        view
        returns (uint256);

    function verifyLeanIMT(
        uint256 root,
        uint256 leaf,
        uint256 index,
        uint256 siblingsLen,
        uint256[32] calldata siblings
    ) external view returns (bool);

    function updateLeanIMTRoot(
        uint256 currentRoot,
        uint256 oldLeaf,
        uint256 newLeaf,
        uint256 index,
        uint256 siblingsLen,
        uint256[32] calldata siblings
    ) external view returns (uint256);

    function computeSMTRoot(uint256 leaf, uint256 index, uint256 enables, uint256[32] calldata siblings)
        external
        view
        returns (uint256);

    function verifySMT(uint256 root, uint256 leaf, uint256 index, uint256 enables, uint256[32] calldata siblings)
        external
        view
        returns (bool);

    function updateSMTRoot(
        uint256 currentRoot,
        uint256 oldLeaf,
        uint256 newLeaf,
        uint256 index,
        uint256 enables,
        uint256[32] calldata siblings
    ) external view returns (uint256);
}

contract ZkKitMerkleBenchTest {
    address private constant HEVM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm private constant vm = Vm(HEVM_ADDRESS);

    IFeZkKitMerkleBench private feSona;
    IFeZkKitMerkleBench private feYul;
    SolidityMerkleBench private sol;

    uint256 private exhaustive;
    uint256 private exhaustiveLeanIMTMaxSiblings;
    uint256 private exhaustiveSMTMaxBits;
    uint256 private exhaustiveValueMax;

    function setUp() public {
        vm.pauseGasMetering();
        // Fe -> Sonatina. Default opt-level 0 (override via `FE_SONA_OPT_LEVEL=1|2`).
        string[] memory cmdSona = new string[](11);
        uint256 sonaOptLevel = vm.envOr("FE_SONA_OPT_LEVEL", uint256(0));
        require(sonaOptLevel <= 2, "BAD_FE_SONA_OPT_LEVEL");
        cmdSona[0] = "fe";
        cmdSona[1] = "build";
        cmdSona[2] = "--backend";
        cmdSona[3] = "sonatina";
        cmdSona[4] = "--opt-level";
        cmdSona[5] = sonaOptLevel == 0 ? "0" : (sonaOptLevel == 1 ? "1" : "2");
        cmdSona[6] = "--out-dir";
        cmdSona[7] = "out/fe/sonatina";
        cmdSona[8] = "--contract";
        cmdSona[9] = "ZkKitMerkleBench";
        cmdSona[10] = "../zkkit_merkle";
        vm.ffi(cmdSona);

        bytes memory deployCodeSona = _hexStringToBytes(vm.readFile("out/fe/sonatina/ZkKitMerkleBench.bin"));
        address feSonaAddr = _deploy(deployCodeSona);
        feSona = IFeZkKitMerkleBench(feSonaAddr);
        _requireRuntimeMatches(feSonaAddr, "out/fe/sonatina/ZkKitMerkleBench.runtime.bin");

        // Fe -> Yul -> solc (optimized via `--optimize`).
        string[] memory cmdYul = new string[](12);
        cmdYul[0] = "fe";
        cmdYul[1] = "build";
        cmdYul[2] = "--backend";
        cmdYul[3] = "yul";
        cmdYul[4] = "--optimize";
        cmdYul[5] = "--solc";
        cmdYul[6] = "/usr/local/bin/solc";
        cmdYul[7] = "--out-dir";
        cmdYul[8] = "out/fe/yul";
        cmdYul[9] = "--contract";
        cmdYul[10] = "ZkKitMerkleBench";
        cmdYul[11] = "../zkkit_merkle";
        vm.ffi(cmdYul);

        bytes memory deployCodeYul = _hexStringToBytes(vm.readFile("out/fe/yul/ZkKitMerkleBench.bin"));
        address feYulAddr = _deploy(deployCodeYul);
        feYul = IFeZkKitMerkleBench(feYulAddr);
        _requireRuntimeMatches(feYulAddr, "out/fe/yul/ZkKitMerkleBench.runtime.bin");

        sol = new SolidityMerkleBench();
        exhaustive = vm.envOr("FE_ZKKIT_EXHAUSTIVE", uint256(0));
        exhaustiveLeanIMTMaxSiblings = vm.envOr("FE_ZKKIT_EXHAUSTIVE_LEANIMT_MAX_SIBLINGS", uint256(5));
        exhaustiveSMTMaxBits = vm.envOr("FE_ZKKIT_EXHAUSTIVE_SMT_MAX_BITS", uint256(5));
        exhaustiveValueMax = vm.envOr("FE_ZKKIT_EXHAUSTIVE_VALUE_MAX", uint256(3));
        vm.resumeGasMetering();
    }

    function _mask32(uint256 x) internal pure returns (uint256) {
        return x & ((uint256(1) << 32) - 1);
    }

    function _popcount32(uint256 x) internal pure returns (uint256 count) {
        x = _mask32(x);
        while (x != 0) {
            count += x & 1;
            x >>= 1;
        }
    }

    function _assertLeanIMTRootsMatch(uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings)
        private
        view
        returns (uint256 root)
    {
        root = sol.computeLeanIMTRoot(leaf, index, siblingsLen, siblings);
        assert(feSona.computeLeanIMTRoot(leaf, index, siblingsLen, siblings) == root);
        assert(feYul.computeLeanIMTRoot(leaf, index, siblingsLen, siblings) == root);
    }

    function _assertSMTRootsMatch(uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings)
        private
        view
        returns (uint256 root)
    {
        root = sol.computeSMTRoot(leaf, index, enables, siblings);
        assert(feSona.computeSMTRoot(leaf, index, enables, siblings) == root);
        assert(feYul.computeSMTRoot(leaf, index, enables, siblings) == root);
    }

    function _hash2(uint256 left, uint256 right) private pure returns (uint256 digest) {
        assembly ("memory-safe") {
            mstore(0x00, left)
            mstore(0x20, right)
            digest := keccak256(0x00, 0x40)
        }
    }

    function _computeLeanIMTRootLocal(uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings)
        private
        pure
        returns (uint256 node)
    {
        if (siblingsLen > 32) {
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }

        node = leaf;
        uint256 idx = index;
        for (uint256 i = 0; i < siblingsLen; i++) {
            uint256 sibling = siblings[i];
            bool isRightChild = (idx & 1) == 1;
            idx >>= 1;
            node = isRightChild ? _hash2(sibling, node) : _hash2(node, sibling);
        }
    }

    function _computeSMTRootLocal(uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings)
        private
        pure
        returns (uint256 node)
    {
        node = leaf;
        uint256 idx = index;

        if (enables == type(uint32).max) {
            for (uint256 i = 0; i < 32; i++) {
                uint256 sibling = siblings[i];
                bool isRightChild = (idx & 1) == 1;
                idx >>= 1;
                node = isRightChild ? _hash2(sibling, node) : _hash2(node, sibling);
            }
            return node;
        }

        uint256 zero = 0;
        uint256 cursor = 0;
        uint256 e = enables;
        for (uint256 i = 0; i < 32; i++) {
            uint256 sibling = (e & 1) == 1 ? siblings[cursor++] : zero;
            e >>= 1;
            bool isRightChild = (idx & 1) == 1;
            idx >>= 1;
            node = isRightChild ? _hash2(sibling, node) : _hash2(node, sibling);
            zero = _hash2(zero, zero);
        }
    }

    function _expandSMTSiblings(uint256 enables, uint256[32] memory packedSiblings)
        private
        pure
        returns (uint256[32] memory fullSiblings)
    {
        uint256 zero = 0;
        uint256 cursor = 0;
        uint256 e = enables;
        for (uint256 i = 0; i < 32; i++) {
            if ((e & 1) == 1) {
                fullSiblings[i] = packedSiblings[cursor++];
            } else {
                fullSiblings[i] = zero;
            }
            e >>= 1;
            zero = _hash2(zero, zero);
        }
    }

    function _assertSMTRootMatchesExpandedLeanIMT(
        uint256 leaf,
        uint256 index,
        uint256 enables,
        uint256[32] memory packedSiblings,
        uint256 solSMTRoot
    ) private view {
        uint256[32] memory fullSiblings = _expandSMTSiblings(enables, packedSiblings);

        uint256 solLeanRoot = sol.computeLeanIMTRoot(leaf, index, 32, fullSiblings);
        assert(solLeanRoot == solSMTRoot);

        assert(feSona.computeLeanIMTRoot(leaf, index, 32, fullSiblings) == solSMTRoot);
        assert(feYul.computeLeanIMTRoot(leaf, index, 32, fullSiblings) == solSMTRoot);
    }

    function testFuzz_LeanIMT_computeRoot_matchesSolidity(
        uint256 leaf,
        uint256 index,
        uint8 siblingsLen0,
        uint256[32] memory siblings
    ) public view {
        uint256 siblingsLen = uint256(siblingsLen0) % 33;
        uint256 solRoot = _assertLeanIMTRootsMatch(leaf, index, siblingsLen, siblings);

        // Invariance: high index bits above `siblingsLen` are ignored.
        uint256 index2 = index ^ (uint256(1) << siblingsLen);
        assert(_assertLeanIMTRootsMatch(leaf, index2, siblingsLen, siblings) == solRoot);

        // Invariance: siblings after `siblingsLen` are ignored.
        for (uint256 i = siblingsLen; i < 32; i++) {
            siblings[i] ^= ((index ^ (i + 1)) | 1);
        }
        assert(_assertLeanIMTRootsMatch(leaf, index, siblingsLen, siblings) == solRoot);
    }

    function test_diff_LeanIMT_computeRoot_smallValues_matchesSolidity() public view {
        uint256 leaf = 1;
        uint256 index = 0;
        uint256 siblingsLen = 2;
        uint256[32] memory siblings;
        siblings[0] = 2;
        siblings[1] = 3;

        uint256 solRoot = sol.computeLeanIMTRoot(leaf, index, siblingsLen, siblings);
        uint256 sonaRoot = feSona.computeLeanIMTRoot(leaf, index, siblingsLen, siblings);
        uint256 yulRoot = feYul.computeLeanIMTRoot(leaf, index, siblingsLen, siblings);
        assert(sonaRoot == solRoot);
        assert(yulRoot == solRoot);
    }

    function testFuzz_LeanIMT_verify_matchesSolidity(
        uint256 leaf,
        uint256 index,
        uint8 siblingsLen0,
        uint256[32] memory siblings
    ) public view {
        uint256 siblingsLen = uint256(siblingsLen0) % 33;
        uint256 root = sol.computeLeanIMTRoot(leaf, index, siblingsLen, siblings);
        assert(feSona.verifyLeanIMT(root, leaf, index, siblingsLen, siblings) == true);
        assert(feYul.verifyLeanIMT(root, leaf, index, siblingsLen, siblings) == true);
        assert(sol.verifyLeanIMT(root, leaf, index, siblingsLen, siblings) == true);

        uint256 badRoot = root ^ 1;
        assert(feSona.verifyLeanIMT(badRoot, leaf, index, siblingsLen, siblings) == false);
        assert(feYul.verifyLeanIMT(badRoot, leaf, index, siblingsLen, siblings) == false);
        assert(sol.verifyLeanIMT(badRoot, leaf, index, siblingsLen, siblings) == false);
    }

    function testFuzz_LeanIMT_updateRoot_matchesSolidity(
        uint256 oldLeaf,
        uint256 newLeaf,
        uint256 index,
        uint8 siblingsLen0,
        uint256[32] memory siblings
    ) public view {
        uint256 siblingsLen = uint256(siblingsLen0) % 33;
        uint256 currentRoot = sol.computeLeanIMTRoot(oldLeaf, index, siblingsLen, siblings);

        uint256 solNewRoot = sol.updateLeanIMTRoot(currentRoot, oldLeaf, newLeaf, index, siblingsLen, siblings);
        assert(feSona.updateLeanIMTRoot(currentRoot, oldLeaf, newLeaf, index, siblingsLen, siblings) == solNewRoot);
        assert(feYul.updateLeanIMTRoot(currentRoot, oldLeaf, newLeaf, index, siblingsLen, siblings) == solNewRoot);

        uint256 badRoot = currentRoot ^ 1;
        {
            (bool ok, ) = _staticcallU256(
                address(feSona),
                abi.encodeWithSelector(
                    IFeZkKitMerkleBench.updateLeanIMTRoot.selector,
                    badRoot,
                    oldLeaf,
                    newLeaf,
                    index,
                    siblingsLen,
                    siblings
                )
            );
            assert(!ok);
        }
        {
            (bool ok, ) = _staticcallU256(
                address(feYul),
                abi.encodeWithSelector(
                    IFeZkKitMerkleBench.updateLeanIMTRoot.selector,
                    badRoot,
                    oldLeaf,
                    newLeaf,
                    index,
                    siblingsLen,
                    siblings
                )
            );
            assert(!ok);
        }
        {
            (bool ok, ) = _staticcallU256(
                address(sol),
                abi.encodeWithSelector(
                    SolidityMerkleBench.updateLeanIMTRoot.selector,
                    badRoot,
                    oldLeaf,
                    newLeaf,
                    index,
                    siblingsLen,
                    siblings
                )
            );
            assert(!ok);
        }
    }

    function test_diff_LeanIMT_updateRoot_revertsOnInvalidProof() public view {
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT();
        uint256 currentRoot = sol.computeLeanIMTRoot(leaf, index, siblingsLen, siblings);

        (bool okSona, ) = _staticcallU256(
            address(feSona),
            abi.encodeWithSelector(
                IFeZkKitMerkleBench.updateLeanIMTRoot.selector,
                currentRoot ^ 1,
                leaf,
                leaf ^ 2,
                index,
                siblingsLen,
                siblings
            )
        );

        (bool okYul, ) = _staticcallU256(
            address(feYul),
            abi.encodeWithSelector(
                IFeZkKitMerkleBench.updateLeanIMTRoot.selector,
                currentRoot ^ 1,
                leaf,
                leaf ^ 2,
                index,
                siblingsLen,
                siblings
            )
        );

        (bool okSol, ) = _staticcallU256(
            address(sol),
            abi.encodeWithSelector(
                SolidityMerkleBench.updateLeanIMTRoot.selector,
                currentRoot ^ 1,
                leaf,
                leaf ^ 2,
                index,
                siblingsLen,
                siblings
            )
        );

        assert(!okSona);
        assert(!okYul);
        assert(!okSol);
    }

    function testFuzz_SMT_computeRoot_matchesSolidity(
        uint256 leaf,
        uint256 index,
        uint256 enables0,
        uint256[32] memory siblings
    ) public view {
        uint256 enables = _mask32(enables0);
        uint256 solRoot = _assertSMTRootsMatch(leaf, index, enables, siblings);
        _assertSMTRootMatchesExpandedLeanIMT(leaf, index, enables, siblings, solRoot);

        // Invariance: high index bits above depth are ignored (depth=32).
        uint256 index2 = index ^ (uint256(1) << 32);
        assert(_assertSMTRootsMatch(leaf, index2, enables, siblings) == solRoot);

        // Invariance: enables only uses the low 32 bits.
        uint256 enables2 = enables | (uint256(1) << 32);
        assert(_assertSMTRootsMatch(leaf, index, enables2, siblings) == solRoot);

        // Invariance: siblings after the packed `popcount(enables)` are ignored.
        uint256 used = _popcount32(enables);
        for (uint256 i = used; i < 32; i++) {
            siblings[i] ^= ((enables + i + 1) | 1);
        }
        assert(_assertSMTRootsMatch(leaf, index, enables, siblings) == solRoot);
    }

    function testFuzz_SMT_verify_matchesSolidity(
        uint256 leaf,
        uint256 index,
        uint256 enables0,
        uint256[32] memory siblings
    ) public view {
        uint256 enables = _mask32(enables0);
        uint256 root = sol.computeSMTRoot(leaf, index, enables, siblings);
        assert(feSona.verifySMT(root, leaf, index, enables, siblings) == true);
        assert(feYul.verifySMT(root, leaf, index, enables, siblings) == true);
        assert(sol.verifySMT(root, leaf, index, enables, siblings) == true);

        uint256 badRoot = root ^ 1;
        assert(feSona.verifySMT(badRoot, leaf, index, enables, siblings) == false);
        assert(feYul.verifySMT(badRoot, leaf, index, enables, siblings) == false);
        assert(sol.verifySMT(badRoot, leaf, index, enables, siblings) == false);
    }

    function testFuzz_SMT_updateRoot_matchesSolidity(
        uint256 oldLeaf,
        uint256 newLeaf,
        uint256 index,
        uint256 enables0,
        uint256[32] memory siblings
    ) public view {
        uint256 enables = _mask32(enables0);
        uint256 currentRoot = sol.computeSMTRoot(oldLeaf, index, enables, siblings);

        uint256 solNewRoot = sol.updateSMTRoot(currentRoot, oldLeaf, newLeaf, index, enables, siblings);
        assert(feSona.updateSMTRoot(currentRoot, oldLeaf, newLeaf, index, enables, siblings) == solNewRoot);
        assert(feYul.updateSMTRoot(currentRoot, oldLeaf, newLeaf, index, enables, siblings) == solNewRoot);

        uint256 badRoot = currentRoot ^ 1;
        {
            (bool ok, ) = _staticcallU256(
                address(feSona),
                abi.encodeWithSelector(
                    IFeZkKitMerkleBench.updateSMTRoot.selector, badRoot, oldLeaf, newLeaf, index, enables, siblings
                )
            );
            assert(!ok);
        }
        {
            (bool ok, ) = _staticcallU256(
                address(feYul),
                abi.encodeWithSelector(
                    IFeZkKitMerkleBench.updateSMTRoot.selector, badRoot, oldLeaf, newLeaf, index, enables, siblings
                )
            );
            assert(!ok);
        }
        {
            (bool ok, ) = _staticcallU256(
                address(sol),
                abi.encodeWithSelector(
                    SolidityMerkleBench.updateSMTRoot.selector, badRoot, oldLeaf, newLeaf, index, enables, siblings
                )
            );
            assert(!ok);
        }
    }

    function test_diff_SMT_updateRoot_revertsOnInvalidProof() public view {
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT();
        uint256 currentRoot = sol.computeSMTRoot(leaf, index, enables, siblings);

        (bool okSona, ) = _staticcallU256(
            address(feSona),
            abi.encodeWithSelector(
                IFeZkKitMerkleBench.updateSMTRoot.selector, currentRoot ^ 1, leaf, leaf ^ 2, index, enables, siblings
            )
        );

        (bool okYul, ) = _staticcallU256(
            address(feYul),
            abi.encodeWithSelector(
                IFeZkKitMerkleBench.updateSMTRoot.selector, currentRoot ^ 1, leaf, leaf ^ 2, index, enables, siblings
            )
        );

        (bool okSol, ) = _staticcallU256(
            address(sol),
            abi.encodeWithSelector(
                SolidityMerkleBench.updateSMTRoot.selector, currentRoot ^ 1, leaf, leaf ^ 2, index, enables, siblings
            )
        );

        assert(!okSona);
        assert(!okYul);
        assert(!okSol);
    }

    function testExhaustive_LeanIMT_smallDomain_matchesSolidity() public view {
        if (exhaustive == 0) return;

        uint256 maxSiblingsLen = exhaustiveLeanIMTMaxSiblings;
        require(maxSiblingsLen <= 8, "BAD_EXHAUSTIVE_MAX_SIBLINGS_LEN");

        uint256 valueMax = exhaustiveValueMax;
        require(valueMax >= 2 && valueMax <= 8, "BAD_EXHAUSTIVE_VALUE_MAX");

        uint256[32] memory siblings;
        for (uint256 siblingsLen = 0; siblingsLen <= maxSiblingsLen; siblingsLen++) {
            uint256 indexMax = uint256(1) << siblingsLen;

            uint256 combos = 1;
            for (uint256 i = 0; i < siblingsLen; i++) {
                combos *= valueMax;
            }

            for (uint256 idx = 0; idx < indexMax; idx++) {
                for (uint256 leaf = 0; leaf < valueMax; leaf++) {
                    for (uint256 c = 0; c < combos; c++) {
                        uint256 tmp = c;
                        for (uint256 i = 0; i < siblingsLen; i++) {
                            siblings[i] = tmp % valueMax;
                            tmp /= valueMax;
                        }

                        uint256 solRoot = sol.computeLeanIMTRoot(leaf, idx, siblingsLen, siblings);
                        uint256 sonaRoot = feSona.computeLeanIMTRoot(leaf, idx, siblingsLen, siblings);
                        uint256 yulRoot = feYul.computeLeanIMTRoot(leaf, idx, siblingsLen, siblings);
                        assert(sonaRoot == solRoot);
                        assert(yulRoot == solRoot);
                    }
                }
            }
        }
    }

    function testExhaustive_SMT_smallDomain_matchesSolidity() public view {
        if (exhaustive == 0) return;

        uint256 maxBits = exhaustiveSMTMaxBits;
        require(maxBits <= 8, "BAD_EXHAUSTIVE_SMT_MAX_BITS");

        uint256 valueMax = exhaustiveValueMax;
        require(valueMax >= 2 && valueMax <= 8, "BAD_EXHAUSTIVE_VALUE_MAX");

        uint256[32] memory siblings;
        uint256 enablesMax = uint256(1) << maxBits;
        uint256 indexMax = uint256(1) << maxBits;

        for (uint256 enables = 0; enables < enablesMax; enables++) {
            uint256 used = _popcount32(enables);

            uint256 combos = 1;
            for (uint256 i = 0; i < used; i++) {
                combos *= valueMax;
            }

            for (uint256 idx = 0; idx < indexMax; idx++) {
                for (uint256 leaf = 0; leaf < valueMax; leaf++) {
                    for (uint256 c = 0; c < combos; c++) {
                        uint256 tmp = c;
                        for (uint256 i = 0; i < used; i++) {
                            siblings[i] = tmp % valueMax;
                            tmp /= valueMax;
                        }
                        for (uint256 i = used; i < maxBits; i++) {
                            siblings[i] = 0;
                        }

                        _assertSMTRootsMatch(leaf, idx, enables, siblings);
                    }
                }
            }
        }
    }

    function test_diff_LeanIMT_computeRoot_revertsOnSiblingsLenGt32() public view {
        uint256[32] memory siblings;

        (bool okSona, ) = _staticcallU256(
            address(feSona),
            abi.encodeWithSelector(IFeZkKitMerkleBench.computeLeanIMTRoot.selector, uint256(1), uint256(0), 33, siblings)
        );

        (bool okYul, ) = _staticcallU256(
            address(feYul),
            abi.encodeWithSelector(IFeZkKitMerkleBench.computeLeanIMTRoot.selector, uint256(1), uint256(0), 33, siblings)
        );

        (bool okSol, ) = _staticcallU256(
            address(sol),
            abi.encodeWithSelector(SolidityMerkleBench.computeLeanIMTRoot.selector, uint256(1), uint256(0), 33, siblings)
        );

        assert(!okSona);
        assert(!okYul);
        assert(!okSol);
    }

    // -------------------------------------------------------------------------
    // Gas benches
    // -------------------------------------------------------------------------

    function testGas_bench_fe_sona_computeLeanIMTRoot_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT();
        bytes memory callData =
            abi.encodeWithSelector(IFeZkKitMerkleBench.computeLeanIMTRoot.selector, leaf, index, siblingsLen, siblings);
        _warm(address(feSona));
        vm.resumeGasMetering();

        (bool ok, uint256 root) = _staticcallU256(address(feSona), callData);

        vm.pauseGasMetering();
        require(ok && root != 0, "FE/sona: computeLeanIMTRoot");
    }

    function testGas_bench_fe_yul_computeLeanIMTRoot_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT();
        bytes memory callData =
            abi.encodeWithSelector(IFeZkKitMerkleBench.computeLeanIMTRoot.selector, leaf, index, siblingsLen, siblings);
        _warm(address(feYul));
        vm.resumeGasMetering();

        (bool ok, uint256 root) = _staticcallU256(address(feYul), callData);

        vm.pauseGasMetering();
        require(ok && root != 0, "FE/yul: computeLeanIMTRoot");
    }

    function testGas_bench_solidity_computeLeanIMTRoot_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT();
        bytes memory callData =
            abi.encodeWithSelector(SolidityMerkleBench.computeLeanIMTRoot.selector, leaf, index, siblingsLen, siblings);
        _warm(address(sol));
        vm.resumeGasMetering();

        (bool ok, uint256 root) = _staticcallU256(address(sol), callData);

        vm.pauseGasMetering();
        require(ok && root != 0, "Solidity: computeLeanIMTRoot");
    }

    function testGas_bench_fe_sona_computeLeanIMTRoot_32Siblings() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT_32();
        bytes memory callData =
            abi.encodeWithSelector(IFeZkKitMerkleBench.computeLeanIMTRoot.selector, leaf, index, siblingsLen, siblings);
        _warm(address(feSona));
        vm.resumeGasMetering();

        (bool ok, uint256 root) = _staticcallU256(address(feSona), callData);

        vm.pauseGasMetering();
        require(ok && root != 0, "FE/sona: computeLeanIMTRoot (32)");
    }

    function testGas_bench_fe_yul_computeLeanIMTRoot_32Siblings() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT_32();
        bytes memory callData =
            abi.encodeWithSelector(IFeZkKitMerkleBench.computeLeanIMTRoot.selector, leaf, index, siblingsLen, siblings);
        _warm(address(feYul));
        vm.resumeGasMetering();

        (bool ok, uint256 root) = _staticcallU256(address(feYul), callData);

        vm.pauseGasMetering();
        require(ok && root != 0, "FE/yul: computeLeanIMTRoot (32)");
    }

    function testGas_bench_solidity_computeLeanIMTRoot_32Siblings() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT_32();
        bytes memory callData =
            abi.encodeWithSelector(SolidityMerkleBench.computeLeanIMTRoot.selector, leaf, index, siblingsLen, siblings);
        _warm(address(sol));
        vm.resumeGasMetering();

        (bool ok, uint256 root) = _staticcallU256(address(sol), callData);

        vm.pauseGasMetering();
        require(ok && root != 0, "Solidity: computeLeanIMTRoot (32)");
    }

    function testGas_bench_fe_sona_updateLeanIMTRoot_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT();
        uint256 currentRoot = _computeLeanIMTRootLocal(leaf, index, siblingsLen, siblings);
        uint256 newLeaf = leaf ^ 0x1234;
        bytes memory callData = abi.encodeWithSelector(
            IFeZkKitMerkleBench.updateLeanIMTRoot.selector,
            currentRoot,
            leaf,
            newLeaf,
            index,
            siblingsLen,
            siblings
        );
        _warm(address(feSona));
        vm.resumeGasMetering();

        (bool ok, uint256 newRoot) = _staticcallU256(address(feSona), callData);

        vm.pauseGasMetering();
        require(ok && newRoot != 0, "FE/sona: updateLeanIMTRoot");
    }

    function testGas_bench_fe_yul_updateLeanIMTRoot_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT();
        uint256 currentRoot = _computeLeanIMTRootLocal(leaf, index, siblingsLen, siblings);
        uint256 newLeaf = leaf ^ 0x1234;
        bytes memory callData = abi.encodeWithSelector(
            IFeZkKitMerkleBench.updateLeanIMTRoot.selector,
            currentRoot,
            leaf,
            newLeaf,
            index,
            siblingsLen,
            siblings
        );
        _warm(address(feYul));
        vm.resumeGasMetering();

        (bool ok, uint256 newRoot) = _staticcallU256(address(feYul), callData);

        vm.pauseGasMetering();
        require(ok && newRoot != 0, "FE/yul: updateLeanIMTRoot");
    }

    function testGas_bench_solidity_updateLeanIMTRoot_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT();
        uint256 currentRoot = _computeLeanIMTRootLocal(leaf, index, siblingsLen, siblings);
        uint256 newLeaf = leaf ^ 0x1234;
        bytes memory callData = abi.encodeWithSelector(
            SolidityMerkleBench.updateLeanIMTRoot.selector,
            currentRoot,
            leaf,
            newLeaf,
            index,
            siblingsLen,
            siblings
        );
        _warm(address(sol));
        vm.resumeGasMetering();

        (bool ok, uint256 newRoot) = _staticcallU256(address(sol), callData);

        vm.pauseGasMetering();
        require(ok && newRoot != 0, "Solidity: updateLeanIMTRoot");
    }

    function testGas_bench_fe_sona_verifyLeanIMT_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT();
        uint256 root = _computeLeanIMTRootLocal(leaf, index, siblingsLen, siblings);
        bytes memory callData = abi.encodeWithSelector(
            IFeZkKitMerkleBench.verifyLeanIMT.selector, root, leaf, index, siblingsLen, siblings
        );
        _warm(address(feSona));
        vm.resumeGasMetering();

        (bool ok, uint256 result) = _staticcallU256(address(feSona), callData);

        vm.pauseGasMetering();
        require(ok && result == 1, "FE/sona: verifyLeanIMT");
    }

    function testGas_bench_fe_yul_verifyLeanIMT_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT();
        uint256 root = _computeLeanIMTRootLocal(leaf, index, siblingsLen, siblings);
        bytes memory callData = abi.encodeWithSelector(
            IFeZkKitMerkleBench.verifyLeanIMT.selector, root, leaf, index, siblingsLen, siblings
        );
        _warm(address(feYul));
        vm.resumeGasMetering();

        (bool ok, uint256 result) = _staticcallU256(address(feYul), callData);

        vm.pauseGasMetering();
        require(ok && result == 1, "FE/yul: verifyLeanIMT");
    }

    function testGas_bench_solidity_verifyLeanIMT_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT();
        uint256 root = _computeLeanIMTRootLocal(leaf, index, siblingsLen, siblings);
        bytes memory callData = abi.encodeWithSelector(
            SolidityMerkleBench.verifyLeanIMT.selector, root, leaf, index, siblingsLen, siblings
        );
        _warm(address(sol));
        vm.resumeGasMetering();

        (bool ok, uint256 result) = _staticcallU256(address(sol), callData);

        vm.pauseGasMetering();
        require(ok && result == 1, "Solidity: verifyLeanIMT");
    }

    function testGas_bench_fe_sona_verifyLeanIMT_32Siblings() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT_32();
        uint256 root = _computeLeanIMTRootLocal(leaf, index, siblingsLen, siblings);
        bytes memory callData = abi.encodeWithSelector(
            IFeZkKitMerkleBench.verifyLeanIMT.selector, root, leaf, index, siblingsLen, siblings
        );
        _warm(address(feSona));
        vm.resumeGasMetering();

        (bool ok, uint256 result) = _staticcallU256(address(feSona), callData);

        vm.pauseGasMetering();
        require(ok && result == 1, "FE/sona: verifyLeanIMT (32)");
    }

    function testGas_bench_fe_yul_verifyLeanIMT_32Siblings() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT_32();
        uint256 root = _computeLeanIMTRootLocal(leaf, index, siblingsLen, siblings);
        bytes memory callData = abi.encodeWithSelector(
            IFeZkKitMerkleBench.verifyLeanIMT.selector, root, leaf, index, siblingsLen, siblings
        );
        _warm(address(feYul));
        vm.resumeGasMetering();

        (bool ok, uint256 result) = _staticcallU256(address(feYul), callData);

        vm.pauseGasMetering();
        require(ok && result == 1, "FE/yul: verifyLeanIMT (32)");
    }

    function testGas_bench_solidity_verifyLeanIMT_32Siblings() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT_32();
        uint256 root = _computeLeanIMTRootLocal(leaf, index, siblingsLen, siblings);
        bytes memory callData = abi.encodeWithSelector(
            SolidityMerkleBench.verifyLeanIMT.selector, root, leaf, index, siblingsLen, siblings
        );
        _warm(address(sol));
        vm.resumeGasMetering();

        (bool ok, uint256 result) = _staticcallU256(address(sol), callData);

        vm.pauseGasMetering();
        require(ok && result == 1, "Solidity: verifyLeanIMT (32)");
    }

    function testGas_bench_fe_sona_updateLeanIMTRoot_32Siblings() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT_32();
        uint256 currentRoot = _computeLeanIMTRootLocal(leaf, index, siblingsLen, siblings);
        uint256 newLeaf = leaf ^ 0x1234;
        bytes memory callData = abi.encodeWithSelector(
            IFeZkKitMerkleBench.updateLeanIMTRoot.selector,
            currentRoot,
            leaf,
            newLeaf,
            index,
            siblingsLen,
            siblings
        );
        _warm(address(feSona));
        vm.resumeGasMetering();

        (bool ok, uint256 newRoot) = _staticcallU256(address(feSona), callData);

        vm.pauseGasMetering();
        require(ok && newRoot != 0, "FE/sona: updateLeanIMTRoot (32)");
    }

    function testGas_bench_fe_yul_updateLeanIMTRoot_32Siblings() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT_32();
        uint256 currentRoot = _computeLeanIMTRootLocal(leaf, index, siblingsLen, siblings);
        uint256 newLeaf = leaf ^ 0x1234;
        bytes memory callData = abi.encodeWithSelector(
            IFeZkKitMerkleBench.updateLeanIMTRoot.selector,
            currentRoot,
            leaf,
            newLeaf,
            index,
            siblingsLen,
            siblings
        );
        _warm(address(feYul));
        vm.resumeGasMetering();

        (bool ok, uint256 newRoot) = _staticcallU256(address(feYul), callData);

        vm.pauseGasMetering();
        require(ok && newRoot != 0, "FE/yul: updateLeanIMTRoot (32)");
    }

    function testGas_bench_solidity_updateLeanIMTRoot_32Siblings() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings) = _demoLeanIMT_32();
        uint256 currentRoot = _computeLeanIMTRootLocal(leaf, index, siblingsLen, siblings);
        uint256 newLeaf = leaf ^ 0x1234;
        bytes memory callData = abi.encodeWithSelector(
            SolidityMerkleBench.updateLeanIMTRoot.selector,
            currentRoot,
            leaf,
            newLeaf,
            index,
            siblingsLen,
            siblings
        );
        _warm(address(sol));
        vm.resumeGasMetering();

        (bool ok, uint256 newRoot) = _staticcallU256(address(sol), callData);

        vm.pauseGasMetering();
        require(ok && newRoot != 0, "Solidity: updateLeanIMTRoot (32)");
    }

    function testGas_bench_fe_sona_computeSMTRoot_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT();
        bytes memory callData =
            abi.encodeWithSelector(IFeZkKitMerkleBench.computeSMTRoot.selector, leaf, index, enables, siblings);
        _warm(address(feSona));
        vm.resumeGasMetering();

        (bool ok, uint256 root) = _staticcallU256(address(feSona), callData);

        vm.pauseGasMetering();
        require(ok && root != 0, "FE/sona: computeSMTRoot");
    }

    function testGas_bench_fe_yul_computeSMTRoot_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT();
        bytes memory callData =
            abi.encodeWithSelector(IFeZkKitMerkleBench.computeSMTRoot.selector, leaf, index, enables, siblings);
        _warm(address(feYul));
        vm.resumeGasMetering();

        (bool ok, uint256 root) = _staticcallU256(address(feYul), callData);

        vm.pauseGasMetering();
        require(ok && root != 0, "FE/yul: computeSMTRoot");
    }

    function testGas_bench_solidity_computeSMTRoot_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT();
        bytes memory callData =
            abi.encodeWithSelector(SolidityMerkleBench.computeSMTRoot.selector, leaf, index, enables, siblings);
        _warm(address(sol));
        vm.resumeGasMetering();

        (bool ok, uint256 root) = _staticcallU256(address(sol), callData);

        vm.pauseGasMetering();
        require(ok && root != 0, "Solidity: computeSMTRoot");
    }

    function testGas_bench_fe_sona_computeSMTRoot_allEnabled() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT_allEnabled();
        bytes memory callData =
            abi.encodeWithSelector(IFeZkKitMerkleBench.computeSMTRoot.selector, leaf, index, enables, siblings);
        _warm(address(feSona));
        vm.resumeGasMetering();

        (bool ok, uint256 root) = _staticcallU256(address(feSona), callData);

        vm.pauseGasMetering();
        require(ok && root != 0, "FE/sona: computeSMTRoot (all enabled)");
    }

    function testGas_bench_fe_yul_computeSMTRoot_allEnabled() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT_allEnabled();
        bytes memory callData =
            abi.encodeWithSelector(IFeZkKitMerkleBench.computeSMTRoot.selector, leaf, index, enables, siblings);
        _warm(address(feYul));
        vm.resumeGasMetering();

        (bool ok, uint256 root) = _staticcallU256(address(feYul), callData);

        vm.pauseGasMetering();
        require(ok && root != 0, "FE/yul: computeSMTRoot (all enabled)");
    }

    function testGas_bench_solidity_computeSMTRoot_allEnabled() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT_allEnabled();
        bytes memory callData =
            abi.encodeWithSelector(SolidityMerkleBench.computeSMTRoot.selector, leaf, index, enables, siblings);
        _warm(address(sol));
        vm.resumeGasMetering();

        (bool ok, uint256 root) = _staticcallU256(address(sol), callData);

        vm.pauseGasMetering();
        require(ok && root != 0, "Solidity: computeSMTRoot (all enabled)");
    }

    function testGas_bench_fe_sona_verifySMT_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT();
        uint256 root = _computeSMTRootLocal(leaf, index, enables, siblings);
        bytes memory callData =
            abi.encodeWithSelector(IFeZkKitMerkleBench.verifySMT.selector, root, leaf, index, enables, siblings);
        _warm(address(feSona));
        vm.resumeGasMetering();

        (bool ok, uint256 result) = _staticcallU256(address(feSona), callData);

        vm.pauseGasMetering();
        require(ok && result == 1, "FE/sona: verifySMT");
    }

    function testGas_bench_fe_yul_verifySMT_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT();
        uint256 root = _computeSMTRootLocal(leaf, index, enables, siblings);
        bytes memory callData =
            abi.encodeWithSelector(IFeZkKitMerkleBench.verifySMT.selector, root, leaf, index, enables, siblings);
        _warm(address(feYul));
        vm.resumeGasMetering();

        (bool ok, uint256 result) = _staticcallU256(address(feYul), callData);

        vm.pauseGasMetering();
        require(ok && result == 1, "FE/yul: verifySMT");
    }

    function testGas_bench_solidity_verifySMT_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT();
        uint256 root = _computeSMTRootLocal(leaf, index, enables, siblings);
        bytes memory callData =
            abi.encodeWithSelector(SolidityMerkleBench.verifySMT.selector, root, leaf, index, enables, siblings);
        _warm(address(sol));
        vm.resumeGasMetering();

        (bool ok, uint256 result) = _staticcallU256(address(sol), callData);

        vm.pauseGasMetering();
        require(ok && result == 1, "Solidity: verifySMT");
    }

    function testGas_bench_fe_sona_verifySMT_allEnabled() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT_allEnabled();
        uint256 root = _computeSMTRootLocal(leaf, index, enables, siblings);
        bytes memory callData =
            abi.encodeWithSelector(IFeZkKitMerkleBench.verifySMT.selector, root, leaf, index, enables, siblings);
        _warm(address(feSona));
        vm.resumeGasMetering();

        (bool ok, uint256 result) = _staticcallU256(address(feSona), callData);

        vm.pauseGasMetering();
        require(ok && result == 1, "FE/sona: verifySMT (all enabled)");
    }

    function testGas_bench_fe_yul_verifySMT_allEnabled() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT_allEnabled();
        uint256 root = _computeSMTRootLocal(leaf, index, enables, siblings);
        bytes memory callData =
            abi.encodeWithSelector(IFeZkKitMerkleBench.verifySMT.selector, root, leaf, index, enables, siblings);
        _warm(address(feYul));
        vm.resumeGasMetering();

        (bool ok, uint256 result) = _staticcallU256(address(feYul), callData);

        vm.pauseGasMetering();
        require(ok && result == 1, "FE/yul: verifySMT (all enabled)");
    }

    function testGas_bench_solidity_verifySMT_allEnabled() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT_allEnabled();
        uint256 root = _computeSMTRootLocal(leaf, index, enables, siblings);
        bytes memory callData =
            abi.encodeWithSelector(SolidityMerkleBench.verifySMT.selector, root, leaf, index, enables, siblings);
        _warm(address(sol));
        vm.resumeGasMetering();

        (bool ok, uint256 result) = _staticcallU256(address(sol), callData);

        vm.pauseGasMetering();
        require(ok && result == 1, "Solidity: verifySMT (all enabled)");
    }

    function testGas_bench_fe_sona_updateSMTRoot_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT();
        uint256 currentRoot = _computeSMTRootLocal(leaf, index, enables, siblings);
        uint256 newLeaf = leaf ^ 0x1234;
        bytes memory callData = abi.encodeWithSelector(
            IFeZkKitMerkleBench.updateSMTRoot.selector, currentRoot, leaf, newLeaf, index, enables, siblings
        );
        _warm(address(feSona));
        vm.resumeGasMetering();

        (bool ok, uint256 newRoot) = _staticcallU256(address(feSona), callData);

        vm.pauseGasMetering();
        require(ok && newRoot != 0, "FE/sona: updateSMTRoot");
    }

    function testGas_bench_fe_yul_updateSMTRoot_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT();
        uint256 currentRoot = _computeSMTRootLocal(leaf, index, enables, siblings);
        uint256 newLeaf = leaf ^ 0x1234;
        bytes memory callData = abi.encodeWithSelector(
            IFeZkKitMerkleBench.updateSMTRoot.selector, currentRoot, leaf, newLeaf, index, enables, siblings
        );
        _warm(address(feYul));
        vm.resumeGasMetering();

        (bool ok, uint256 newRoot) = _staticcallU256(address(feYul), callData);

        vm.pauseGasMetering();
        require(ok && newRoot != 0, "FE/yul: updateSMTRoot");
    }

    function testGas_bench_solidity_updateSMTRoot_typical() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT();
        uint256 currentRoot = _computeSMTRootLocal(leaf, index, enables, siblings);
        uint256 newLeaf = leaf ^ 0x1234;
        bytes memory callData = abi.encodeWithSelector(
            SolidityMerkleBench.updateSMTRoot.selector, currentRoot, leaf, newLeaf, index, enables, siblings
        );
        _warm(address(sol));
        vm.resumeGasMetering();

        (bool ok, uint256 newRoot) = _staticcallU256(address(sol), callData);

        vm.pauseGasMetering();
        require(ok && newRoot != 0, "Solidity: updateSMTRoot");
    }

    function testGas_bench_fe_sona_updateSMTRoot_allEnabled() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT_allEnabled();
        uint256 currentRoot = _computeSMTRootLocal(leaf, index, enables, siblings);
        uint256 newLeaf = leaf ^ 0x1234;
        bytes memory callData = abi.encodeWithSelector(
            IFeZkKitMerkleBench.updateSMTRoot.selector, currentRoot, leaf, newLeaf, index, enables, siblings
        );
        _warm(address(feSona));
        vm.resumeGasMetering();

        (bool ok, uint256 newRoot) = _staticcallU256(address(feSona), callData);

        vm.pauseGasMetering();
        require(ok && newRoot != 0, "FE/sona: updateSMTRoot (all enabled)");
    }

    function testGas_bench_fe_yul_updateSMTRoot_allEnabled() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT_allEnabled();
        uint256 currentRoot = _computeSMTRootLocal(leaf, index, enables, siblings);
        uint256 newLeaf = leaf ^ 0x1234;
        bytes memory callData = abi.encodeWithSelector(
            IFeZkKitMerkleBench.updateSMTRoot.selector, currentRoot, leaf, newLeaf, index, enables, siblings
        );
        _warm(address(feYul));
        vm.resumeGasMetering();

        (bool ok, uint256 newRoot) = _staticcallU256(address(feYul), callData);

        vm.pauseGasMetering();
        require(ok && newRoot != 0, "FE/yul: updateSMTRoot (all enabled)");
    }

    function testGas_bench_solidity_updateSMTRoot_allEnabled() public {
        vm.pauseGasMetering();
        (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings) = _demoSMT_allEnabled();
        uint256 currentRoot = _computeSMTRootLocal(leaf, index, enables, siblings);
        uint256 newLeaf = leaf ^ 0x1234;
        bytes memory callData = abi.encodeWithSelector(
            SolidityMerkleBench.updateSMTRoot.selector, currentRoot, leaf, newLeaf, index, enables, siblings
        );
        _warm(address(sol));
        vm.resumeGasMetering();

        (bool ok, uint256 newRoot) = _staticcallU256(address(sol), callData);

        vm.pauseGasMetering();
        require(ok && newRoot != 0, "Solidity: updateSMTRoot (all enabled)");
    }

    // -------------------------------------------------------------------------
    // Test vectors
    // -------------------------------------------------------------------------

    function _demoLeanIMT()
        private
        pure
        returns (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings)
    {
        leaf = uint256(keccak256("leaf"));
        index = 11;
        siblingsLen = 7;
        siblings[0] = uint256(keccak256("sib0"));
        siblings[1] = uint256(keccak256("sib1"));
        siblings[2] = uint256(keccak256("sib2"));
        siblings[3] = uint256(keccak256("sib3"));
        siblings[4] = uint256(keccak256("sib4"));
        siblings[5] = uint256(keccak256("sib5"));
        siblings[6] = uint256(keccak256("sib6"));
    }

    function _demoLeanIMT_32()
        private
        pure
        returns (uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] memory siblings)
    {
        leaf = uint256(keccak256("leaf"));
        index = 0x1234_5678;
        siblingsLen = 32;
        for (uint256 i = 0; i < 32; i++) {
            siblings[i] = uint256(keccak256(abi.encodePacked("sib", i)));
        }
    }

    function _demoSMT()
        private
        pure
        returns (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings)
    {
        leaf = uint256(keccak256("leaf"));
        index = 0x1234_5678;
        enables = 0;

        // Enable siblings at a few levels; siblings are packed in order.
        enables |= 1 << 0;
        enables |= 1 << 3;
        enables |= 1 << 5;
        enables |= 1 << 12;
        enables |= 1 << 31;

        siblings[0] = uint256(keccak256("s0"));
        siblings[1] = uint256(keccak256("s3"));
        siblings[2] = uint256(keccak256("s5"));
        siblings[3] = uint256(keccak256("s12"));
        siblings[4] = uint256(keccak256("s31"));
    }

    function _demoSMT_allEnabled()
        private
        pure
        returns (uint256 leaf, uint256 index, uint256 enables, uint256[32] memory siblings)
    {
        leaf = uint256(keccak256("leaf"));
        index = 0x1234_5678;
        enables = type(uint32).max;
        for (uint256 i = 0; i < 32; i++) {
            siblings[i] = uint256(keccak256(abi.encodePacked("s", i)));
        }
    }

    // -------------------------------------------------------------------------
    // Low-level helpers
    // -------------------------------------------------------------------------

    function _staticcallU256(address target, bytes memory callData) private view returns (bool ok, uint256 result) {
        uint256 out;
        assembly ("memory-safe") {
            ok := staticcall(gas(), target, add(callData, 0x20), mload(callData), 0x00, 0x20)
            out := mload(0x00)
        }

        return (ok, out);
    }

    function _warm(address target) private view {
        assembly ("memory-safe") {
            pop(extcodesize(target))
        }
    }

    function _deploy(bytes memory creationCode) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0), "DEPLOY_FAILED");
    }

    function _requireRuntimeMatches(address deployed, string memory runtimePath) private {
        bytes memory expected = _hexStringToBytes(vm.readFile(runtimePath));
        bytes memory actual = deployed.code;
        require(keccak256(actual) == keccak256(expected), "RUNTIME_MISMATCH");
    }

    function _hexStringToBytes(string memory s) private pure returns (bytes memory) {
        bytes memory strBytes = bytes(s);
        uint256 start = 0;
        uint256 end = strBytes.length;

        while (start < end && _isWhitespace(strBytes[start])) {
            start++;
        }
        while (end > start && _isWhitespace(strBytes[end - 1])) {
            end--;
        }

        if (
            end >= start + 2 && strBytes[start] == 0x30
                && (strBytes[start + 1] == 0x78 || strBytes[start + 1] == 0x58)
        ) {
            start += 2;
        }

        uint256 hexLen = end - start;
        require(hexLen % 2 == 0, "HEX_ODD_LENGTH");

        bytes memory out = new bytes(hexLen / 2);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] =
                bytes1((_fromHexChar(strBytes[start + 2 * i]) << 4) | _fromHexChar(strBytes[start + 2 * i + 1]));
        }
        return out;
    }

    function _isWhitespace(bytes1 c) private pure returns (bool) {
        return c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;
    }

    function _fromHexChar(bytes1 c) private pure returns (uint8) {
        uint8 b = uint8(c);
        if (b >= 48 && b <= 57) {
            return b - 48;
        }
        if (b >= 65 && b <= 70) {
            return b - 55;
        }
        if (b >= 97 && b <= 102) {
            return b - 87;
        }
        revert("HEX_BAD_CHAR");
    }
}
