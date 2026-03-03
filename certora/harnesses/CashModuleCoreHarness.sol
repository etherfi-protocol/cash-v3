import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { SafeCashConfig } from "../../src/interfaces/ICashModule.sol";

contract CashModuleCoreHarness is CashModuleCore {
    constructor (address _etherFiDataProvider) payable CashModuleCore(_etherFiDataProvider) {}

    // Getters
    function getSafeAdminRole(address safe) external view returns (uint256) {
        return uint256(etherFiDataProvider.roleRegistry().getSafeAdminRole(safe));
    }

    function getAssets(address user) external view returns(uint256 totalBalance) {
        address[] memory tokens = this.getWhitelistedWithdrawAssets();
        uint256 len = tokens.length;

        for (uint256 i = 0; i < len; i++) {
          totalBalance += IERC20(tokens[i]).balanceOf(user);
        }
    }

    function getWithdrawRequestsAmountForToken(address safe, address token) external view returns(uint256) {
        SafeCashConfig storage safeCashConfig = _getCashModuleStorage().safeCashConfig[safe];
        uint256 len = safeCashConfig.pendingWithdrawalRequest.tokens.length;
        uint256 tokenIndex = len;
        for (uint256 i = 0; i < len;) {
            if (safeCashConfig.pendingWithdrawalRequest.tokens[i] == token) {
                tokenIndex = i;
                break;
            }
            unchecked {
                ++i;
            }
        }

        // If the token does not exist in withdrawal request, return
        if (tokenIndex == len) return 0;

        return _getCashModuleStorage().safeCashConfig[safe].pendingWithdrawalRequest.amounts[tokenIndex];
    }

    function getWithdrawRequestsLength(address safe) public view returns(uint256) {
        return _getCashModuleStorage().safeCashConfig[safe].pendingWithdrawalRequest.tokens.length;
    }


     function getBalanceOf(address safe, address token) public view returns(uint256) {
        return IERC20(token).balanceOf(safe);
     }

     function isCashbackToken(address token) public view returns (bool) {
        CashModuleStorage storage $ = _getCashModuleStorage();
        return $.cashbackDispatcher.isCashbackToken(token);
     }

     function convertUsdToCashbackToken(uint256 cashbackInUsd, address cashbackToken) public view returns (uint256) {
        if (cashbackInUsd == 0) return 0;
        CashModuleStorage storage $ = _getCashModuleStorage();

        return $.cashbackDispatcher.convertUsdToCashbackToken(cashbackToken, cashbackInUsd);
     }
}
