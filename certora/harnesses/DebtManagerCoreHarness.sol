import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { ICashModule, BinSponsor } from "../../src/interfaces/ICashModule.sol";

contract DebtManagerCoreHarness is DebtManagerCore {
    constructor (address _dataProvider) payable DebtManagerCore(_dataProvider) {}

    // Getters
    function getSafeAdminRole(address safe) external view returns (uint256) {
        return uint256(etherFiDataProvider.roleRegistry().getSafeAdminRole(safe));
    }

    function getNormalizedDebt(address user, address token) external view returns (uint256) {
        DebtManagerStorage storage $ = _getDebtManagerStorage();
        return $.userNormalizedBorrowings[user][token];
    }

    function getSettlementDispatcher(BinSponsor binSponsor) external view returns (address) {
        return ICashModule(etherFiDataProvider.getCashModule()).getSettlementDispatcher(binSponsor);
    }

    function getBalanceOf(address user, address token) external view returns (uint256) {
        return IERC20(token).balanceOf(user);
    }

    function getInterestIndex(address token) external view returns (uint256) {
        return _getDebtManagerStorage().borrowTokenConfig[token].interestIndexSnapshot;
    }
}
