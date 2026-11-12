// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

interface IERC20Allowance {
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface ICheckIn {
    function owner() external view returns (address);
    function last() external view returns (uint256);
}

/// Idea A's vault, on the destination chain. It holds nothing: the owner keeps his tokens in his own wallet and gives
/// this contract an allowance, which he can revoke at any time. Only SilenceWatch's callbacks move it. On release it
/// first re-checks the owner's CheckIn on this chain: a check-in newer than `quiet` (the watch's silence + grace) is a
/// sign the watch never saw, stuck in transit or missed, so it refuses and stays locked. It can only re-check this
/// chain; a sign stuck on another chain is the watch's to count. After a release anyone may call distribute(token),
/// which moves the owner's tokens to the heirs by their fixed shares. It hands over funds, never keys.
contract HeirVault is AbstractCallback {
    enum Stage { Armed, Warning, Released, Refused }

    struct Heir {
        address to;
        uint256 share;
    }

    address public immutable owner;
    ICheckIn public immutable checkIn;
    uint256 public immutable quiet;
    uint256 public immutable totalShares;

    Heir[] internal _heirs;
    Stage public stage;
    uint256 public releasedAt;

    event Warned(uint256 at);
    event Cancelled(uint256 at);
    event Released(uint256 at);
    event ReleaseRefused(uint256 at, uint256 lastCheckIn);
    event Distributed(address indexed token, address indexed heir, uint256 amount);

    constructor(IPayable callbackProxy_, address watch_, ICheckIn checkIn_, uint256 quiet_, Heir[] memory heirs_)
        payable
        AbstractCallback(callbackProxy_, watch_)
    {
        require(heirs_.length > 0 && quiet_ > 0, "config");
        owner = checkIn_.owner();
        checkIn = checkIn_;
        quiet = quiet_;
        uint256 total;
        for (uint256 i; i < heirs_.length; i++) {
            require(heirs_[i].to != address(0) && heirs_[i].to != owner && heirs_[i].share > 0, "heir");
            _heirs.push(heirs_[i]);
            total += heirs_[i].share;
        }
        totalShares = total;
    }

    // The callbacks' first argument is the reactive contract, written in by the network (never trusted from the payload
    // alone: onlyServiceProvider proves the proxy delivered it). `at_` is the watch's own time.

    function onWarn(address watch_, uint256 at_) external onlyServiceProvider onlyCallbackSender(watch_) {
        if (stage != Stage.Armed) return;
        stage = Stage.Warning;
        emit Warned(at_);
    }

    function onCancel(address watch_, uint256 at_) external onlyServiceProvider onlyCallbackSender(watch_) {
        if (stage != Stage.Warning) return;
        stage = Stage.Armed;
        emit Cancelled(at_);
    }

    /// Accepted from Armed too: a lost warning must not keep the heirs waiting forever; the re-check below is the guard.
    function onRelease(address watch_, uint256) external onlyServiceProvider onlyCallbackSender(watch_) {
        if (stage == Stage.Released || stage == Stage.Refused) return;
        uint256 last = checkIn.last();
        if (block.timestamp - last < quiet) {
            // stays locked; how to re-arm after a refusal is an open design point (Fable's audit, 11-16)
            stage = Stage.Refused;
            emit ReleaseRefused(block.timestamp, last);
            return;
        }
        stage = Stage.Released;
        releasedAt = block.timestamp;
        emit Released(block.timestamp);
    }

    /// Moves as much of `token_` as both the owner's allowance and his balance allow, split by shares (the last heir
    /// also gets the rounding dust). Callable again for tokens that reach his wallet later, while the allowance lasts.
    /// No reentrancy guard: a nested call spends the allowance or balance this loop counted on, so it reverts whole.
    function distribute(address token_) external {
        require(stage == Stage.Released, "not released");
        IERC20Allowance token = IERC20Allowance(token_);
        uint256 amount = token.allowance(owner, address(this));
        uint256 balance = token.balanceOf(owner);
        if (balance < amount) amount = balance;
        require(amount > 0, "nothing to move");
        uint256 left = amount;
        for (uint256 i; i < _heirs.length; i++) {
            uint256 part = i + 1 == _heirs.length ? left : amount * _heirs[i].share / totalShares;
            left -= part;
            if (part == 0) continue;
            // tokens that return nothing (USDT style) are accepted; one that returns false stops it all
            (bool ok, bytes memory ret) = token_.call(abi.encodeCall(IERC20Allowance.transferFrom, (owner, _heirs[i].to, part)));
            require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "transfer failed");
            emit Distributed(token_, _heirs[i].to, part);
        }
    }

    function heirs() external view returns (Heir[] memory) {
        return _heirs;
    }

    /// Settles a debt from this contract's balance (a contract in debt gets no callbacks, so the release never comes).
    function coverDebt() external {
        _coverDebt();
    }
}
