// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {FHE, euint256} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import {IRouteEngine} from "../interfaces/IRouteEngine.sol";
import {IPhantomAdapter} from "../interfaces/IPhantomAdapter.sol";
import {Order} from "../types/PhantomOrder.sol";

/// @title RouteEngine
/// @notice Performs encrypted route selection across registered adapters using CoFHE primitives.
contract RouteEngine is IRouteEngine, Ownable {
    struct AdapterConfig {
        bool enabled;
    }

    struct AdapterHint {
        address adapter;
        bytes data;
        uint256 plaintextScore;
    }

    error AdapterAlreadyRegistered(address adapter);
    error AdapterNotRegistered(address adapter);
    error NoActiveAdapters();
    error InvalidAdapter();

    event AdapterRegistered(address indexed adapter);
    event AdapterRemoved(address indexed adapter);

    address[] private _adapters;
    mapping(address => AdapterConfig) private _configs;
    mapping(address => uint256) private _indexes; // 1-based index for existence tracking.

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Registers a new liquidity adapter for route evaluation.
    function registerAdapter(address adapter) external onlyOwner {
        if (adapter == address(0)) revert InvalidAdapter();
        if (_configs[adapter].enabled) revert AdapterAlreadyRegistered(adapter);

        _configs[adapter] = AdapterConfig({enabled: true});
        _adapters.push(adapter);
        _indexes[adapter] = _adapters.length;

        emit AdapterRegistered(adapter);
    }

    /// @notice Removes an adapter from consideration.
    function removeAdapter(address adapter) external onlyOwner {
        if (!_configs[adapter].enabled) revert AdapterNotRegistered(adapter);

        delete _configs[adapter];

        uint256 idx = _indexes[adapter];
        uint256 lastIdx = _adapters.length;

        if (idx != 0 && idx != lastIdx) {
            address last = _adapters[lastIdx - 1];
            _adapters[idx - 1] = last;
            _indexes[last] = idx;
        }

        if (lastIdx != 0) {
            _adapters.pop();
        }
        delete _indexes[adapter];

        emit AdapterRemoved(adapter);
    }

    /// @notice Returns the list of currently registered adapters.
    function getAdapters() external view returns (address[] memory adapters) {
        adapters = _adapters;
    }

    /// @inheritdoc IRouteEngine
    function selectBestRoute(bytes32 orderHash, Order calldata order, bytes calldata extraData)
        external
        override
        returns (RouteSelection memory selection)
    {
        address[] memory adaptersSnapshot = _adapters;
        if (adaptersSnapshot.length == 0) revert NoActiveAdapters();

        AdapterHint[] memory hints =
            extraData.length != 0 ? abi.decode(extraData, (AdapterHint[])) : new AdapterHint[](0);

        bool found;
        uint256 bestScore;
        for (uint256 i = 0; i < adaptersSnapshot.length; ++i) {
            address adapterAddr = adaptersSnapshot[i];
            if (!_configs[adapterAddr].enabled) continue;

            (bytes memory hintData, uint256 hintScore) = _hintFor(adapterAddr, hints);
            IPhantomAdapter.Quote memory quote = IPhantomAdapter(adapterAddr).requestQuote(orderHash, order, hintData);

            FHE.allowThis(quote.encryptedAmountOut);

            uint256 comparisonMetric = hintScore != 0 ? hintScore : euint256.unwrap(quote.encryptedAmountOut);

            if (!found) {
                selection.adapter = adapterAddr;
                selection.quote = quote;
                selection.adapterData = hintData.length != 0 ? hintData : quote.adapterData;
                selection.encryptedQuote = quote.encryptedAmountOut;
                found = true;
                bestScore = comparisonMetric;
                continue;
            }

            if (comparisonMetric > bestScore) {
                selection.adapter = adapterAddr;
                selection.quote = quote;
                selection.adapterData = hintData.length != 0 ? hintData : quote.adapterData;
                selection.encryptedQuote = quote.encryptedAmountOut;
                bestScore = comparisonMetric;
            }
        }

        if (!found) revert NoActiveAdapters();

        // Ensure the caller (typically PhantomSwap) can operate with the resulting ciphertext.
        FHE.allow(selection.encryptedQuote, msg.sender);
    }

    function _hintFor(address adapter, AdapterHint[] memory hints)
        internal
        pure
        returns (bytes memory data, uint256 score)
    {
        for (uint256 i = 0; i < hints.length; ++i) {
            if (hints[i].adapter == adapter) {
                return (hints[i].data, hints[i].plaintextScore);
            }
        }
        return ("", 0);
    }
}

