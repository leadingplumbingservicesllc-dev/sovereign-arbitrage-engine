// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import "../contracts/SovereignRouter.sol";

interface Vm {
    function envUint(string calldata) external returns (uint256);
    function envAddress(string calldata) external returns (address);
    function envOr(string calldata, string calldata) external returns (string memory);
    function readFile(string calldata) external returns (string memory);
    function parseJsonAddressArray(string calldata, string calldata) external returns (address[] memory);
    function startBroadcast(uint256) external;
    function stopBroadcast() external;
}

contract Deploy {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (SovereignRouter router) {
        string memory policy = vm.readFile(vm.envOr("DEPLOY_POLICY_PATH", string("deploy-policy.json")));
        address[] memory tokens = vm.parseJsonAddressArray(policy, ".tokens");
        address[] memory uni = vm.parseJsonAddressArray(policy, ".uniswap_v3_routers");
        address[] memory camelot = vm.parseJsonAddressArray(policy, ".camelot_v1_routers");
        require(tokens.length >= 2 && uni.length + camelot.length > 0, "Empty policy");
        vm.startBroadcast(vm.envUint("DEPLOYER_KEY"));
        router = new SovereignRouter(
            vm.envAddress("AAVE_POOL"),
            vm.envAddress("EXECUTOR_ADDRESS"),
            vm.envAddress("BENEFICIARY_ADDRESS"),
            vm.envUint("MAX_LOAN"),
            vm.envUint("MAX_PREMIUM_BPS"),
            3
        );
        for (uint256 i; i < tokens.length; i++) {
            router.setPolicy(tokens[i], true, 1);
        }
        for (uint256 i; i < uni.length; i++) {
            router.setPolicy(uni[i], false, 1);
        }
        for (uint256 i; i < camelot.length; i++) {
            router.setPolicy(camelot[i], false, 2);
        }
        vm.stopBroadcast();
    }
}
