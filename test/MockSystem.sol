// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// Stands in for the system contract at 0x8888…8888, which on Lasna is also the callback proxy.
/// It only records subscriptions and callback requests; the test plays the network and delivers them.
contract MockSystem {
    struct Sub { address subscriber; uint256 chainId; address origin; uint256 topic0; }
    struct Req { address requester; uint256 chainId; address recipient; uint64 gasLimit; bytes payload; }

    Sub[] internal _subs;
    Req[] internal _reqs;
    uint256 internal _owed;
    uint256 internal _reserves;
    uint256 internal _coeffPer1000;
    uint256 internal _extra;

    function subscribe(uint256 chainId_, address contract_, uint256 topic0_, uint256, uint256, uint256) external {
        _subs.push(Sub(msg.sender, chainId_, contract_, topic0_));
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c_) external {
        _reqs.push(Req(msg.sender, c_.chainId, c_.recipient, c_.gasLimit, c_.payload));
    }

    function debt(address) external view returns (uint256) {
        return _owed;
    }

    function reserves(address) external view returns (uint256) {
        return _reserves;
    }

    function _gasPriceCoeffPer1000() external view returns (uint256) {
        return _coeffPer1000;
    }

    function _extraGas() external view returns (uint256) {
        return _extra;
    }

    function setDebt(uint256 owed_) external {
        _owed = owed_;
    }

    function setReserves(uint256 reserves_) external {
        _reserves = reserves_;
    }

    function setFees(uint256 coeffPer1000_, uint256 extra_) external {
        _coeffPer1000 = coeffPer1000_;
        _extra = extra_;
    }

    receive() external payable {}

    function subs() external view returns (Sub[] memory) {
        return _subs;
    }

    /// Hands over the pending requests and forgets them.
    function takeRequests() external returns (Req[] memory out) {
        out = _reqs;
        delete _reqs;
    }
}
