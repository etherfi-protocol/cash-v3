// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Plain mintable 18-decimal token.
contract PlainToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Burns `feeBps` of every transfer (mints are exempt), so the recipient receives less than sent.
contract FeeOnTransferToken is ERC20 {
    uint256 public constant FEE_BPS = 100; // 1%

    constructor() ERC20("Fee On Transfer", "FOT") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) return super._update(from, to, value);
        uint256 fee = value * FEE_BPS / 10_000;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

/// @dev `transfer` returns false without moving anything while `failTransfers` is set. The safe's
///      module path only checks call success, so CashModule believes the withdrawal went through.
contract FalseReturnToken is ERC20 {
    bool public failTransfers = true;

    constructor() ERC20("False Return", "FALSE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailTransfers(bool fail) external {
        failTransfers = fail;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (failTransfers) return false;
        return super.transfer(to, value);
    }
}

/// @dev Minimal ERC-20 whose balances can be scaled down for every holder at once (negative rebase).
///      Balances are stored directly, so transfers move exact amounts; `rebase` rounds each holder down.
contract NegativeRebaseToken {
    string public constant name = "Negative Rebase";
    string public constant symbol = "NRB";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    address[] internal holders;
    mapping(address => bool) internal isHolder;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        _track(to);
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @dev Scales every holder's balance by `numerator / denominator` (rounded down).
    function rebase(uint256 numerator, uint256 denominator) external {
        require(numerator <= denominator, "negative rebase only");
        uint256 supply;
        for (uint256 i = 0; i < holders.length; i++) {
            uint256 scaled = balanceOf[holders[i]] * numerator / denominator;
            balanceOf[holders[i]] = scaled;
            supply += scaled;
        }
        totalSupply = supply;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        allowance[from][msg.sender] -= value;
        _move(from, to, value);
        return true;
    }

    function _move(address from, address to, uint256 value) internal {
        _track(to);
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    function _track(address account) internal {
        if (!isHolder[account]) {
            isHolder[account] = true;
            holders.push(account);
        }
    }
}

/// @dev ERC-20 that, when armed, calls `target` with `payload` from inside every `transfer`. With
///      `bubble` set the inner revert propagates; otherwise the outcome is recorded and the transfer
///      continues, so a test can assert both that reentry was refused and that the outer call is intact.
contract ReentrantToken is ERC20 {
    address public target;
    bytes public payload;
    bool public bubble;
    bool public armed;

    bool public lastReentrySucceeded;
    bytes public lastReentryError;
    uint256 public reentryAttempts;

    constructor() ERC20("Reentrant", "REENTER") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_, bool bubble_) external {
        target = target_;
        payload = payload_;
        bubble = bubble_;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool ok = super.transfer(to, value);
        if (armed) {
            armed = false; // one attempt per arm
            reentryAttempts++;
            (bool success, bytes memory ret) = target.call(payload);
            lastReentrySucceeded = success;
            lastReentryError = ret;
            if (!success && bubble) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return ok;
    }
}
