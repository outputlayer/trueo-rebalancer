// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockOutcomeToken} from "../../mocks/MockOutcomeToken.sol";
import {MockMarketManager} from "../../mocks/MockMarketManager.sol";

/// @notice Test-only variant of test/mocks/MockTruthMarket.sol whose mint/burn rule is decimals-based (as the specification
/// says TruthMarketV2's is): one payment unit mints 10**(outcomeDecimals - paymentDecimals) outcome units of each
/// side; burning n of each pays n / 10**gap. Same gates as the fixture mock. No immutables (uniform codehash).
contract DecTruthMarket {
    MockMarketManager public manager;
    ERC20 public paymentToken;
    MockOutcomeToken public yesToken;
    MockOutcomeToken public noToken;
    PoolKey internal _yesKey;
    PoolKey internal _noKey;
    uint256 public factor;
    uint256 public yesNoTokenCap = type(uint256).max;
    bool public paused;
    uint8 public status;

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
        factor = 10 ** (uint256(_yes.decimals()) - uint256(_pay.decimals()));
        _yesKey = _keyFor(address(_yes), address(_pay), fee, spacing, hook);
        _noKey = _keyFor(address(_no), address(_pay), fee, spacing, hook);
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function setStatus(uint8 s) external {
        status = s;
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
        uint256 tokenAmount = paymentTokenAmount * factor;
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
        require(paymentToken.transfer(msg.sender, amount / factor), "pay");
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
