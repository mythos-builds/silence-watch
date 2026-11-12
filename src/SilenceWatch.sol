// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// The system contract's billing views (dev.reactive.network/economy). Its owner can change the fee settings, so the
/// docs say to read them, not assume them. Reserves = credit prepaid with depositTo(), spent before our own balance.
interface ISystemBilling {
    function _gasPriceCoeffPer1000() external view returns (uint256);
    function _extraGas() external view returns (uint256);
    function reserves(address contract_) external view returns (uint256);
}

/// Idea A's clock: counts the owner's silence on Cron ticks. After `silence` seconds without a sign of life it
/// warns (stage 1) and opens a grace period in which any sign cancels; only after `grace` more seconds does it
/// ask the vault to release (stage 2). Signs count only from the CheckIn contracts named at deploy time.
/// The clock is this chain's time when react() runs, so a late or missed log delays a release instead of causing
/// one, unless a sign is stuck in transit for longer than the grace period: the vault checks again on its chain.
contract SilenceWatch is AbstractReactive {
    enum Stage { Armed, Warning, Released }

    struct Source {
        uint256 chainId;
        address checkIn;
    }

    /// Emits the Cron events; only validator root addresses can make it fire.
    address public constant CRON_SOURCE = 0x0000000000000000000000000000000000fffFfF;
    uint256 public constant ALIVE_TOPIC0 = uint256(keccak256("Alive(address,uint256)"));
    // The relayer sends this as the whole transaction's gas limit, and the proxy keeps _extraGas + _maxChargeGas
    // (150 000 on Lasna, 200 000 on Sepolia) before it forwards the rest. 300 000 ran the vault out of gas on Sepolia,
    // where a fresh storage slot now costs about 100 000 (onWarn measured 112 000, 2026-11-12). Fees count the gas
    // used, not this limit.
    uint64 public constant CALLBACK_GAS = 1_000_000;
    /// Gas an idle tick is billed for, the system's surcharge aside: react() (about 33 000 in the tests), plus the
    /// transaction's 21 000 and a margin, so fundedUntil() errs early (the safe side).
    uint256 public constant TICK_GAS = 65_000;

    address public immutable owner;
    uint256 public immutable cronTopic;
    uint256 public immutable silence;
    uint256 public immutable grace;
    uint256 public immutable vaultChainId;
    address public immutable vault;

    Source[] internal _sources;
    Stage public stage;
    // Measured at each real Cron tick, packed with `stage` in one slot (one extra write per tick): when the last tick
    // ran, the gap before it, and the gas price it paid.
    uint40 public lastTick;
    uint40 public tickEvery;
    uint96 public tickPrice;
    uint256 public lastSign;
    uint256 public warnedAt;

    event Sign(uint256 indexed chainId, address indexed source, uint256 at);
    event Warned(uint256 at, uint256 releaseAfter);
    event Cancelled(uint256 at);
    event Released(uint256 at);

    constructor(
        address owner_,
        uint256 cronTopic_,
        uint256 silence_,
        uint256 grace_,
        Source[] memory sources_,
        uint256 vaultChainId_,
        address vault_
    ) payable {
        require(sources_.length > 0 && silence_ > 0 && grace_ > 0, "config");
        owner = owner_;
        cronTopic = cronTopic_;
        silence = silence_;
        grace = grace_;
        vaultChainId = vaultChainId_;
        vault = vault_;
        lastSign = block.timestamp;
        SYSTEM.subscribe(block.chainid, CRON_SOURCE, cronTopic_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        for (uint256 i; i < sources_.length; i++) {
            _sources.push(sources_[i]);
            // never address(0) here: an open contract filter lets anyone fake a sign and drain our balance
            SYSTEM.subscribe(sources_[i].chainId, sources_[i].checkIn, ALIVE_TOPIC0, uint256(uint160(owner_)), REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.chainId == block.chainid && log_.contractAddress == CRON_SOURCE && log_.topic0 == cronTopic) {
            _tick();
        } else if (
            log_.topic0 == ALIVE_TOPIC0 && log_.topic1 == uint256(uint160(owner)) && _isSource(log_.chainId, log_.contractAddress)
        ) {
            _sign(log_.chainId, log_.contractAddress);
        }
    }

    function sources() external view returns (Source[] memory) {
        return _sources;
    }

    /// Settles a debt from this contract's balance (a contract in debt is silently skipped).
    function coverDebt() external {
        _coverDebt();
    }

    /// When the balance stops paying for Cron ticks: the last tick plus the ticks still paid for, at the measured gap
    /// and price (0 until two ticks have run; meaningless once Released). Every tick is billed even when nothing
    /// happens, and a contract in debt is skipped silently: past this time the watch stops and the heirs get nothing,
    /// so top it up well before: depositTo(this) on the system contract, or a plain transfer (then coverDebt() if it
    /// is already in debt).
    function fundedUntil() external view returns (uint256) {
        uint256 fee = tickFee();
        if (tickEvery == 0 || fee == 0) return 0;
        uint256 funds = ISystemBilling(address(SYSTEM)).reserves(address(this)) + address(this).balance;
        uint256 owed = SYSTEM.debt(address(this));
        uint256 left = funds > owed ? funds - owed : 0;
        return lastTick + left / fee * tickEvery;
    }

    /// One idle tick's fee at the last measured price: p_base · C · (g_used + K) (dev.reactive.network/economy).
    function tickFee() public view returns (uint256) {
        ISystemBilling fees = ISystemBilling(address(SYSTEM));
        return uint256(tickPrice) * fees._gasPriceCoeffPer1000() * (TICK_GAS + fees._extraGas()) / 1000;
    }

    function _tick() internal {
        // every real tick, idle or not: fundedUntil() extrapolates from the last gap and price
        if (lastTick != 0) tickEvery = uint40(block.timestamp - lastTick);
        lastTick = uint40(block.timestamp);
        tickPrice = uint96(tx.gasprice > block.basefee ? tx.gasprice : block.basefee); // the fee's p_base
        if (stage == Stage.Armed) {
            if (block.timestamp - lastSign < silence) return;
            stage = Stage.Warning;
            warnedAt = block.timestamp;
            emit Warned(block.timestamp, block.timestamp + grace);
            _callback("onWarn(address,uint256)");
        } else if (stage == Stage.Warning) {
            if (block.timestamp - warnedAt < grace) return;
            stage = Stage.Released;
            emit Released(block.timestamp);
            _callback("onRelease(address,uint256)");
            // nothing left to count: stop paying for ticks
            SYSTEM.unsubscribe(block.chainid, CRON_SOURCE, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    function _sign(uint256 chainId_, address source_) internal {
        if (stage == Stage.Released) {
            // too late here; the vault's own check is the last guard. Drop this source, so its later signs stop
            // billing us. Done here, not on the release tick: a failing unsubscribe can't hold the release back.
            SYSTEM.unsubscribe(chainId_, source_, ALIVE_TOPIC0, uint256(uint160(owner)), REACTIVE_IGNORE, REACTIVE_IGNORE);
            return;
        }
        lastSign = block.timestamp;
        emit Sign(chainId_, source_, block.timestamp);
        if (stage == Stage.Warning) {
            stage = Stage.Armed;
            warnedAt = 0;
            emit Cancelled(block.timestamp);
            _callback("onCancel(address,uint256)");
        }
    }

    function _isSource(uint256 chainId_, address contract_) internal view returns (bool) {
        for (uint256 i; i < _sources.length; i++) {
            if (_sources[i].chainId == chainId_ && _sources[i].checkIn == contract_) return true;
        }
        return false;
    }

    function _callback(string memory signature_) internal {
        SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0({
            chainId: vaultChainId,
            recipient: vault,
            gasLimit: CALLBACK_GAS,
            // the first argument is a placeholder: the network overwrites it with this contract's address
            payload: abi.encodeWithSignature(signature_, address(0), block.timestamp)
        }));
    }
}
