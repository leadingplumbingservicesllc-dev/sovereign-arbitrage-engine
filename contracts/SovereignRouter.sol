// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IPool {
    function flashLoanSimple(address, address, uint256, bytes calldata, uint16) external;
}

interface IUni {
    struct Params {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(Params calldata) external payable returns (uint256);
}

interface ICamelot {
    struct Params {
        address tokenIn;
        address tokenOut;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 limitSqrtPrice;
    }
    function exactInputSingle(Params calldata) external payable returns (uint256);
}

/// @notice Owner-curated, executor-operated atomic round trips. Supports Uniswap V3 SwapRouter
/// and Camelot Algebra V1 SwapRouter; Router02/Algebra Integral require distinct adapters.
contract SovereignRouter {
    error Unauthorized();
    error UnsafeParameters();
    error TokenCallFailed();
    error InvalidCallback();
    error Unprofitable(uint256 balance, uint256 required);
    enum Phase {
        Idle,
        Requested,
        Callback,
        Settled
    }

    struct Leg {
        address router;
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint8 kind;
        uint256 minOut;
    }

    struct Plan {
        address asset;
        uint256 amount;
        uint256 minProfit;
        uint256 maxPremium;
        uint256 deadline;
        uint256 nonce;
        Leg[] legs;
    }
    address public owner;
    address public pendingOwner;
    address public executor;
    address public immutable pool;
    address public immutable beneficiary;
    Phase public phase;
    bool public paused;
    uint256 public nonce;
    uint256 public attempts;
    uint256 public successes;
    uint256 public rejected;
    uint256 public maxLoan;
    uint256 public maxPremiumBps;
    uint256 public immutable failureThreshold;
    uint256 private baseline;
    bytes32 private commitment;
    mapping(address => bool) public tokens;
    mapping(address => uint8) public routers;
    event Executed(uint256 indexed nonce, address indexed asset, uint256 amount, uint256 premium, uint256 profit);
    event Rejected(uint256 indexed nonce, uint256 count);
    event PauseChanged(bool paused);
    event PolicyChanged(address indexed target, bool token, uint8 kind);
    event ExecutorChanged(address indexed executor);
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(
        address pool_,
        address executor_,
        address beneficiary_,
        uint256 maxLoan_,
        uint256 maxPremiumBps_,
        uint256 threshold_
    ) {
        if (
            pool_.code.length == 0 || executor_ == address(0) || beneficiary_ == address(0) || maxLoan_ == 0
                || maxPremiumBps_ > 100 || threshold_ == 0
        ) revert UnsafeParameters();
        owner = msg.sender;
        pool = pool_;
        executor = executor_;
        beneficiary = beneficiary_;
        maxLoan = maxLoan_;
        maxPremiumBps = maxPremiumBps_;
        failureThreshold = threshold_;
    }

    function nominateOwner(address next) external onlyOwner {
        if (next == address(0)) revert UnsafeParameters();
        pendingOwner = next;
    }

    function acceptOwner() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function setExecutor(address next) external onlyOwner {
        if (phase != Phase.Idle || next == address(0)) revert UnsafeParameters();
        executor = next;
        emit ExecutorChanged(next);
    }

    function setPolicy(address target, bool token, uint8 kind) external onlyOwner {
        if (phase != Phase.Idle || target.code.length == 0 || kind > 2) revert UnsafeParameters();
        if (token) tokens[target] = kind != 0;
        else routers[target] = kind;
        emit PolicyChanged(target, token, kind);
    }

    function setPaused(bool value) external onlyOwner {
        if (phase != Phase.Idle) revert UnsafeParameters();
        paused = value;
        if (!value) rejected = 0;
        emit PauseChanged(value);
    }

    function execute(Plan calldata plan) external returns (bool) {
        if (msg.sender != executor) revert Unauthorized();
        if (phase != Phase.Idle || paused) revert UnsafeParameters();
        attempts++;
        // A non-reverting rejection can persist a circuit breaker. Reverted EVM calls cannot.
        if (!_valid(plan)) {
            rejected++;
            if (rejected >= failureThreshold) {
                paused = true;
                emit PauseChanged(true);
            }
            emit Rejected(plan.nonce, rejected);
            return false;
        }
        nonce++;
        baseline = IERC20(plan.asset).balanceOf(address(this));
        bytes memory payload = abi.encode(plan);
        commitment = keccak256(payload);
        phase = Phase.Requested;
        IPool(pool).flashLoanSimple(address(this), plan.asset, plan.amount, payload, 0);
        if (phase != Phase.Settled) revert InvalidCallback();
        uint256 ending = IERC20(plan.asset).balanceOf(address(this));
        if (ending < baseline + plan.minProfit) revert Unprofitable(ending, baseline + plan.minProfit);
        uint256 profit = ending - baseline;
        _approve(plan.asset, pool, 0);
        // Keep the state locked through token transfers.
        _call(plan.asset, abi.encodeCall(IERC20.transfer, (beneficiary, profit)));
        phase = Phase.Idle;
        successes++;
        rejected = 0;
        commitment = bytes32(0);
        return true;
    }

    function _valid(Plan calldata p) private view returns (bool) {
        if (
            !tokens[p.asset] || p.amount == 0 || p.amount > maxLoan || p.minProfit == 0 || p.nonce != nonce
                || p.deadline < block.timestamp || p.deadline > block.timestamp + 120
                || p.maxPremium > p.amount * maxPremiumBps / 10000 || p.legs.length < 2 || p.legs.length > 4
        ) return false;
        address current = p.asset;
        for (uint256 i; i < p.legs.length; i++) {
            Leg calldata l = p.legs[i];
            if (
                !tokens[l.tokenOut] || l.tokenIn != current || l.tokenOut == current || l.minOut == 0 || l.kind == 0
                    || l.kind != routers[l.router] || (l.kind == 1 && (l.fee == 0 || l.fee >= 1000000))
            ) return false;
            current = l.tokenOut;
        }
        return current == p.asset;
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        if (
            msg.sender != pool || initiator != address(this) || phase != Phase.Requested
                || keccak256(params) != commitment
        ) revert InvalidCallback();
        Plan memory p = abi.decode(params, (Plan));
        if (
            asset != p.asset || amount != p.amount || premium > p.maxPremium
                || IERC20(asset).balanceOf(address(this)) < baseline + amount
        ) revert UnsafeParameters();
        phase = Phase.Callback;
        uint256 output = amount;
        for (uint256 i; i < p.legs.length; i++) {
            Leg memory l = p.legs[i];
            uint256 beforeOut = IERC20(l.tokenOut).balanceOf(address(this));
            _approve(l.tokenIn, l.router, output);
            if (l.kind == 1) {
                IUni(l.router)
                    .exactInputSingle(
                        IUni.Params(l.tokenIn, l.tokenOut, l.fee, address(this), p.deadline, output, l.minOut, 0)
                    );
            } else {
                ICamelot(l.router)
                    .exactInputSingle(
                        ICamelot.Params(l.tokenIn, l.tokenOut, address(this), p.deadline, output, l.minOut, 0)
                    );
            }
            _approve(l.tokenIn, l.router, 0);
            output = IERC20(l.tokenOut).balanceOf(address(this)) - beforeOut;
            if (output < l.minOut) revert UnsafeParameters();
        }
        uint256 required = baseline + amount + premium + p.minProfit;
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < required) revert Unprofitable(balance, required);
        _approve(asset, pool, amount + premium);
        phase = Phase.Settled;
        emit Executed(p.nonce, asset, amount, premium, balance - baseline - amount - premium);
        return true;
    }

    function _approve(address token, address spender, uint256 amount) private {
        _call(token, abi.encodeCall(IERC20.approve, (spender, 0)));
        if (amount != 0) _call(token, abi.encodeCall(IERC20.approve, (spender, amount)));
    }

    function _call(address token, bytes memory data) private {
        (bool ok, bytes memory result) = token.call(data);
        if (!ok || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert TokenCallFailed();
        }
    }
}
