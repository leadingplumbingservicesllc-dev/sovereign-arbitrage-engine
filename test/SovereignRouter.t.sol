// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import "../contracts/SovereignRouter.sol";

contract Token is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address who, uint256 n) external {
        balanceOf[who] += n;
    }

    function approve(address who, uint256 n) external returns (bool) {
        allowance[msg.sender][who] = n;
        return true;
    }

    function transfer(address to, uint256 n) external returns (bool) {
        balanceOf[msg.sender] -= n;
        balanceOf[to] += n;
        return true;
    }

    function transferFrom(address from, address to, uint256 n) external {
        allowance[from][msg.sender] -= n;
        balanceOf[from] -= n;
        balanceOf[to] += n;
    }
}

contract Pool is IPool {
    function flashLoanSimple(address to, address asset, uint256 amount, bytes calldata data, uint16) external {
        Token(asset).transfer(to, amount);
        require(SovereignRouter(to).executeOperation(asset, amount, 1, to, data));
        Token(asset).transferFrom(to, address(this), amount + 1);
    }
}

contract Dex is IUni {
    uint256 public bonus = 10;

    function setBonus(uint256 n) external {
        bonus = n;
    }

    function exactInputSingle(Params calldata p) external payable returns (uint256) {
        Token(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        Token(p.tokenOut).mint(p.recipient, p.amountIn + bonus);
        return p.amountIn + bonus;
    }
}

contract CamelotDex is ICamelot {
    function exactInputSingle(Params calldata p) external payable returns (uint256) {
        Token(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        Token(p.tokenOut).mint(p.recipient, p.amountIn + 10);
        return p.amountIn + 10;
    }
}

contract SovereignRouterTest {
    Token a;
    Token b;
    Pool pool;
    Dex dex;
    SovereignRouter router;

    function setUp() public {
        a = new Token();
        b = new Token();
        pool = new Pool();
        dex = new Dex();
        router = new SovereignRouter(address(pool), address(this), address(this), 100000, 100, 2);
        router.setPolicy(address(a), true, 1);
        router.setPolicy(address(b), true, 1);
        router.setPolicy(address(dex), false, 1);
        a.mint(address(pool), 100000);
    }

    function plan() internal view returns (SovereignRouter.Plan memory p) {
        SovereignRouter.Leg[] memory legs = new SovereignRouter.Leg[](2);
        legs[0] = SovereignRouter.Leg(address(dex), address(a), address(b), 3000, 1, 1000);
        legs[1] = SovereignRouter.Leg(address(dex), address(b), address(a), 3000, 1, 1000);
        p = SovereignRouter.Plan(address(a), 1000, 10, 1, block.timestamp + 60, router.nonce(), legs);
    }

    function testRoundTripAndRepayment() public {
        require(router.execute(plan()));
        require(a.balanceOf(address(this)) == 19);
        require(a.balanceOf(address(pool)) == 100001);
        require(router.successes() == 1);
        require(a.allowance(address(router), address(pool)) == 0);
    }

    function testPrefundedBalancePreserved() public {
        a.mint(address(router), 100);
        router.execute(plan());
        require(a.balanceOf(address(router)) == 100);
    }

    function testLossRevertsAllState() public {
        dex.setBonus(0);
        (bool ok, bytes memory reason) = address(router).call(abi.encodeCall(router.execute, (plan())));
        require(!ok);
        require(bytes4(reason) == SovereignRouter.Unprofitable.selector);
        require(router.nonce() == 0);
        require(router.attempts() == 0);
        require(a.balanceOf(address(pool)) == 100000);
    }

    function testCircuitBreakerPersistsRejections() public {
        SovereignRouter.Plan memory p = plan();
        p.amount = 0;
        require(!router.execute(p));
        require(!router.execute(p));
        require(router.paused());
        require(router.rejected() == 2);
    }

    function testFakeCallbackRejected() public {
        (bool ok,) = address(router)
            .call(abi.encodeCall(router.executeOperation, (address(a), 1000, 1, address(router), bytes(""))));
        require(!ok);
    }

    function testExpiredPlanRejected() public {
        SovereignRouter.Plan memory p = plan();
        p.deadline = 0;
        require(!router.execute(p));
    }

    function testCamelotDispatch() public {
        CamelotDex camelot = new CamelotDex();
        router.setPolicy(address(camelot), false, 2);
        SovereignRouter.Plan memory p = plan();
        p.legs[1].router = address(camelot);
        p.legs[1].kind = 2;
        p.legs[1].fee = 0;
        require(router.execute(p));
        require(a.balanceOf(address(this)) == 19);
    }

    function testUnapprovedRouterRejected() public {
        SovereignRouter.Plan memory p = plan();
        p.legs[0].router = address(pool);
        require(!router.execute(p));
    }

    function testFuzzProfit(uint96 donation) public {
        a.mint(address(router), donation);
        router.execute(plan());
        require(a.balanceOf(address(router)) == donation);
    }
}
