// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title AaveV4DevRoles
 * @notice Role ids the dev Aave v4 test instance was deployed with (the aave-v4 v0.5.11 Roles
 *         library). The launch-branch Roles library renumbered role ids (hub 100s, spoke 300s)
 *         and the prod whitelabel instance uses that scheme, but the dev AccessManager still maps
 *         selectors to the original ids, so they are pinned here as deployed facts.
 */
library AaveV4DevRoles {
    uint64 constant HUB_ADMIN_ROLE = 1;
    uint64 constant SPOKE_ADMIN_ROLE = 2;
}
