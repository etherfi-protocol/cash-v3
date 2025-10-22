import "cvlPrice.spec";
import "erc20cvl.spec";
import "cvlMath.spec";

using UpgradeableProxy as upgradeableProxy;

methods {
  function _.decimals() external => DISPATCHER(true);
  function _.proxiableUUID() external with (env e) => cvlProxiableUUID(e) expect bytes32;

  function _.isValidSignature(bytes32, bytes) external => NONDET; // The ERC1271 signature validation for contracts
  function _.recover(bytes32, bytes memory) internal => NONDET; // The ECDSA signature recover for contracts
  function _.setupModule(bytes) external => DISPATCHER(true);

  function CREATE3.predictDeterministicAddress(bytes32, address) internal returns (address) => NONDET; 
  function CREATE3.deployDeterministic(uint256, bytes memory, bytes32) internal returns (address) => NONDET; 
}

function cvlProxiableUUID(env e) returns bytes32 {
  return upgradeableProxy.proxiableUUID(e);
}
