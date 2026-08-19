import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { IEtherFiHook } from "../../src/interfaces/IEtherFiHook.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract EtherFiSafeHarness is EtherFiSafe {
    constructor (address _dataProvider) payable EtherFiSafe(_dataProvider) {}

    // Getters
    function getSafeAdminRole(address safe) external view returns (uint256) {
        return uint256(dataProvider.roleRegistry().getSafeAdminRole(safe));
    }

    function getCashModule() public view returns (address) {
        return address(dataProvider.getCashModule());
    }

    function execTransactionFromModuleRepay(address token, address safe, address debtManager, uint256 amount) external {
        if (!isModuleEnabled(msg.sender)) revert OnlyModules();
        IEtherFiHook hook = IEtherFiHook(dataProvider.getHookAddress());

        if (address(hook) != address(0)) hook.preOpHook(msg.sender);

        IERC20(token).approve(debtManager, amount);
        IDebtManager(debtManager).repay(safe, token, amount);
        IERC20(token).approve(debtManager, 0);

        if (address(hook) != address(0)) hook.postOpHook(msg.sender);
    }
}
