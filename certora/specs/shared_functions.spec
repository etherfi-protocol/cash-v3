
function cvlSetRole(address holder, uint256 role, bool active) {
    // No-op
}

function cvlConfigureSafeAdmins() {
    // No-op
}

ghost address stargateAdmin;
ghost address safeFactoryAdmin;
ghost address cashModuleAdmin;
ghost address etherFiWallet;
ghost address dataProviderAdmin;
ghost address safe; // Note: this is different from others
ghost address pauser;
ghost address unpauser;

definition stargateAdminRole() returns uint256 = require_uint256(keccak256("STARGATE_MODULE_ADMIN_ROLE"));
definition safeFactoryAdminRole() returns uint256 = require_uint256(keccak256("ETHERFI_SAFE_FACTORY_ADMIN_ROLE"));
definition cashModuleAdminRole() returns uint256 = require_uint256(keccak256("CASH_MODULE_CONTROLLER_ROLE"));
definition etherFiWalletRole() returns uint256 = require_uint256(keccak256("ETHER_FI_WALLET_ROLE"));
definition dataProviderAdminRole() returns uint256 = require_uint256(keccak256("DATA_PROVIDER_ADMIN_ROLE"));
definition pauserRole() returns uint256 = require_uint256(keccak256("PAUSER"));
definition unpauserRole() returns uint256 = require_uint256(keccak256("UNPAUSER"));

function cvlHasRole(address holder, uint256 role) returns bool {
    if (role == safeFactoryAdminRole()) {
        return holder == safeFactoryAdmin;
    } else if (role == cashModuleAdminRole()) {
        return holder == cashModuleAdmin;
    } else if (role == etherFiWalletRole()) {
        return holder == etherFiWallet;
    } else if (role == dataProviderAdminRole()) {
        return holder == dataProviderAdmin;
    } else if (role == getSafeAdminRole(safe)) {
        return holder == safe;
    } else if (role == pauserRole()) {
        return holder == pauser;
    } else if (role == unpauserRole()) {
        return holder == unpauser;
    } else if (role == stargateAdminRole()) {
        return holder == stargateAdmin;
    }  else {
        return false;
    }
}

function cvlRoleHolders(uint256 role) returns address[] {
    if (role == safeFactoryAdminRole()) {
        return [safeFactoryAdmin];
    } else if (role == cashModuleAdminRole()) {
        return [cashModuleAdmin];
    } else if (role == etherFiWalletRole()) {
        return [etherFiWallet];
    } else if (role == dataProviderAdminRole()) {
        return [dataProviderAdmin];
    } else if (role == getSafeAdminRole(safe)) {
        return [safe];
    } else if (role == pauserRole()) {
        return [pauser];
    } else if (role == unpauserRole()) {
        return [unpauser];
    } else if (role == safeFactoryAdminRole()) {
        return [stargateAdmin];
    } else {
        return [];
    }
}
