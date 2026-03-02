// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Solidity reference implementation matching `zkkit_merkle`'s Keccak-based helpers.
contract SolidityMerkleBench {
    error InvalidSiblingsLen();
    error RootMismatch();

    function _zeroTable() internal pure returns (uint256[32] memory t) {
        t[0]  = 0;
        t[1]  = 0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5;
        t[2]  = 0xb4c11951957c6f8f642c4af61cd6b24640fec6dc7fc607ee8206a99e92410d30;
        t[3]  = 0x21ddb9a356815c3fac1026b6dec5df3124afbadb485c9ba5a3e3398a04b7ba85;
        t[4]  = 0xe58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344;
        t[5]  = 0x0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d;
        t[6]  = 0x887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968;
        t[7]  = 0xffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83;
        t[8]  = 0x9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af;
        t[9]  = 0xcefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0;
        t[10] = 0xf9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5;
        t[11] = 0xf8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892;
        t[12] = 0x3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c;
        t[13] = 0xc1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb;
        t[14] = 0x5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc;
        t[15] = 0xda7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2;
        t[16] = 0x2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f;
        t[17] = 0xe1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a;
        t[18] = 0x5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0;
        t[19] = 0xb46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0;
        t[20] = 0xc65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2;
        t[21] = 0xf4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9;
        t[22] = 0x5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377;
        t[23] = 0x4df84f40ae0c8229d0d6069e5c8f39a7c299677a09d367fc7b05e3bc380ee652;
        t[24] = 0xcdc72595f74c7b1043d0e1ffbab734648c838dfb0527d971b602bc216c9619ef;
        t[25] = 0x0abf5ac974a1ed57f4050aa510dd9c74f508277b39d7973bb2dfccc5eeb0618d;
        t[26] = 0xb8cd74046ff337f0a7bf2c8e03e10f642c1886798d71806ab1e888d9e5ee87d0;
        t[27] = 0x838c5655cb21c6cb83313b5a631175dff4963772cce9108188b34ac87c81c41e;
        t[28] = 0x662ee4dd2dd7b2bc707961b1e646c4047669dcb6584f0d8d770daf5d7e7deb2e;
        t[29] = 0x388ab20e2573d171a88108e79d820e98f26c0b84aa8b2f4aa4968dbb818ea322;
        t[30] = 0x93237c50ba75ee485f4c22adf2f741400bdf8d6a9cc7df7ecae576221665d735;
        t[31] = 0x8448818bb4ae4562849e949e17ac16e0be16688e156b5cf15e098c627c0056a9;
    }

    function _hash2(uint256 left, uint256 right) internal pure returns (uint256 digest) {
        assembly {
            mstore(0x00, left)
            mstore(0x20, right)
            digest := keccak256(0x00, 0x40)
        }
    }

    function _computeLeanIMTRoot(uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] calldata siblings)
        internal
        pure
        returns (uint256 node)
    {
        if (siblingsLen > 32) revert InvalidSiblingsLen();

        node = leaf;
        uint256 idx = index;
        for (uint256 i = 0; i < siblingsLen; i++) {
            uint256 sibling = siblings[i];
            bool isRightChild = (idx & 1) == 1;
            idx >>= 1;
            if (isRightChild) {
                node = _hash2(sibling, node);
            } else {
                node = _hash2(node, sibling);
            }
        }
    }

    function computeLeanIMTRoot(uint256 leaf, uint256 index, uint256 siblingsLen, uint256[32] calldata siblings)
        external
        pure
        returns (uint256)
    {
        return _computeLeanIMTRoot(leaf, index, siblingsLen, siblings);
    }

    function verifyLeanIMT(
        uint256 root,
        uint256 leaf,
        uint256 index,
        uint256 siblingsLen,
        uint256[32] calldata siblings
    ) external pure returns (bool) {
        return _computeLeanIMTRoot(leaf, index, siblingsLen, siblings) == root;
    }

    function updateLeanIMTRoot(
        uint256 currentRoot,
        uint256 oldLeaf,
        uint256 newLeaf,
        uint256 index,
        uint256 siblingsLen,
        uint256[32] calldata siblings
    ) external pure returns (uint256) {
        if (siblingsLen > 32) revert InvalidSiblingsLen();

        uint256 oldNode = oldLeaf;
        uint256 newNode = newLeaf;
        uint256 idx = index;
        for (uint256 i = 0; i < siblingsLen; i++) {
            uint256 sibling = siblings[i];
            bool isRightChild = (idx & 1) == 1;
            idx >>= 1;
            if (isRightChild) {
                oldNode = _hash2(sibling, oldNode);
                newNode = _hash2(sibling, newNode);
            } else {
                oldNode = _hash2(oldNode, sibling);
                newNode = _hash2(newNode, sibling);
            }
        }
        if (oldNode != currentRoot) revert RootMismatch();
        return newNode;
    }

    function _computeSMTRoot(uint256 leaf, uint256 index, uint256 enables, uint256[32] calldata siblings)
        internal
        pure
        returns (uint256 node)
    {
        node = leaf;
        uint256 idx = index;

        // Fast path: if all siblings are enabled, we never need the default `zero` nodes.
        if (enables == type(uint32).max) {
            for (uint256 i = 0; i < 32; i++) {
                uint256 sibling = siblings[i];
                bool isRightChild = (idx & 1) == 1;
                idx >>= 1;
                node = isRightChild ? _hash2(sibling, node) : _hash2(node, sibling);
            }
            return node;
        }

        uint256[32] memory zeros = _zeroTable();
        uint256 cursor = 0;

        for (uint256 i = 0; i < 32; i++) {
            uint256 sibling = (enables & 1) == 1 ? siblings[cursor++] : zeros[i];
            enables >>= 1;

            bool isRightChild = (idx & 1) == 1;
            idx >>= 1;
            if (isRightChild) {
                node = _hash2(sibling, node);
            } else {
                node = _hash2(node, sibling);
            }
        }
    }

    function computeSMTRoot(uint256 leaf, uint256 index, uint256 enables, uint256[32] calldata siblings)
        external
        pure
        returns (uint256)
    {
        return _computeSMTRoot(leaf, index, enables, siblings);
    }

    function verifySMT(uint256 root, uint256 leaf, uint256 index, uint256 enables, uint256[32] calldata siblings)
        external
        pure
        returns (bool)
    {
        return _computeSMTRoot(leaf, index, enables, siblings) == root;
    }

    function updateSMTRoot(
        uint256 currentRoot,
        uint256 oldLeaf,
        uint256 newLeaf,
        uint256 index,
        uint256 enables,
        uint256[32] calldata siblings
    ) external pure returns (uint256) {
        uint256 oldNode = oldLeaf;
        uint256 newNode = newLeaf;
        uint256 idx = index;

        if (enables == type(uint32).max) {
            for (uint256 i = 0; i < 32; i++) {
                uint256 sibling = siblings[i];
                bool isRightChild = (idx & 1) == 1;
                idx >>= 1;
                if (isRightChild) {
                    oldNode = _hash2(sibling, oldNode);
                    newNode = _hash2(sibling, newNode);
                } else {
                    oldNode = _hash2(oldNode, sibling);
                    newNode = _hash2(newNode, sibling);
                }
            }
            if (oldNode != currentRoot) revert RootMismatch();
            return newNode;
        }

        uint256[32] memory zeros = _zeroTable();
        uint256 cursor = 0;

        for (uint256 i = 0; i < 32; i++) {
            uint256 sibling = (enables & 1) == 1 ? siblings[cursor++] : zeros[i];
            enables >>= 1;

            bool isRightChild = (idx & 1) == 1;
            idx >>= 1;
            if (isRightChild) {
                oldNode = _hash2(sibling, oldNode);
                newNode = _hash2(sibling, newNode);
            } else {
                oldNode = _hash2(oldNode, sibling);
                newNode = _hash2(newNode, sibling);
            }
        }
        if (oldNode != currentRoot) revert RootMismatch();
        return newNode;
    }
}
