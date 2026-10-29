// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockOutcomeToken} from "./MockOutcomeToken.sol";
import {MockMarketManager} from "./MockMarketManager.sol";

/// @notice TruthMarketV2 stand-in with the same mint/burn arithmetic and gates (TruthMarketV2.sol:344-377).
/// No immutables, so every instance has the same codehash.
contract MockTruthMarket {
    MockMarketManager public manager;
    ERC20 public paymentToken;
    MockOutcomeToken public yesToken;
    MockOutcomeToken public noToken;
    PoolKey internal _yesKey;
    PoolKey internal _noKey;
    uint256 public yesNoTokenCap = type(uint256).max;
    bool public paused;
    uint8 public status; // MarketStatus; 7 = Finalized

    function init(
        MockMarketManager _manager,
        ERC20 _pay,
        MockOutcomeToken _yes,
        MockOutcomeToken _no,
        uint24 fee,
        int24 spacing,
        address hook
    ) external {
        manager = _manager;
        paymentToken = _pay;
        yesToken = _yes;
        noToken = _no;
        _yesKey = _keyFor(address(_yes), address(_pay), fee, spacing, hook);
        _noKey = _keyFor(address(_no), address(_pay), fee, spacing, hook);
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function setStatus(uint8 s) external {
        status = s;
    }

    function setCap(uint256 c) external {
        yesNoTokenCap = c;
    }

    function getCurrentStatus() external view returns (uint8) {
        return status;
    }

    function getPoolKeys() external view returns (PoolKey memory, PoolKey memory) {
        return (_yesKey, _noKey);
    }

    function mint(uint256 paymentTokenAmount) external {
        require(!manager.paused() && !paused, "paused");
        require(status != 7, "finalized");
        uint256 tokenAmount = paymentTokenAmount * 1e12;
        require(
            yesToken.totalSupply() + tokenAmount <= yesNoTokenCap
                && noToken.totalSupply() + tokenAmount <= yesNoTokenCap,
            "cap"
        );
        require(paymentToken.transferFrom(msg.sender, address(this), paymentTokenAmount), "pay");
        yesToken.mint(msg.sender, tokenAmount);
        noToken.mint(msg.sender, tokenAmount);
    }

    function burn(uint256 amount) external {
        require(!manager.paused() && !paused, "paused");
        require(status != 7, "finalized");
        yesToken.burnFrom(msg.sender, amount);
        noToken.burnFrom(msg.sender, amount);
        require(paymentToken.transfer(msg.sender, amount / 1e12), "pay");
    }

    function _keyFor(address outcome, address pay, uint24 fee, int24 spacing, address hook)
        internal
        pure
        returns (PoolKey memory)
    {
        (address c0, address c1) = outcome < pay ? (outcome, pay) : (pay, outcome);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(hook));
    }
}
