// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./GovChecker.sol";

import "./interface/IEnvStorage.sol";
import "./interface/IStaking.sol";

contract Staking is GovChecker, ReentrancyGuard, IStaking {

    mapping(address => uint256) private _balance;
    mapping(address => uint256) private _lockedBalance;
    uint256 private _totalLockedBalance;
    bool private revoked = false;

    //====NXTMeta====//
    event Staked(address indexed payee, uint256 amount, uint256 total, uint256 available);
    event Unstaked(address indexed payee, uint256 amount, uint256 total, uint256 available);
    event Locked(address indexed payee, uint256 amount, uint256 total, uint256 available);
    event Unlocked(address indexed payee, uint256 amount, uint256 total, uint256 available);
    event TransferLocked(address indexed payee, uint256 amount, uint256 total, uint256 available);
    event Revoked(address indexed owner, uint256 amount);

    constructor(address registry, bytes memory data) {
        _totalLockedBalance = 0;
        _transferOwnership(_msgSender());
        setRegistry(registry);

        // data is only for test purpose
        if (data.length == 0)
            return;

        // []{address, amount}
        address addr;
        uint amount;
        uint ix;
        uint eix;
        assembly {
            ix := add(data, 0x20)
        }
        eix = ix + data.length;
        while (ix < eix) {
            assembly {
                addr := mload(ix)
            }
            ix += 0x20;
            require(ix < eix);
            assembly {
                amount := mload(ix)
            }
            ix += 0x20;

            _balance[addr] = amount;
            _lockedBalance[addr] = amount;
            _totalLockedBalance += amount;
        }
    }

    receive() external payable {
        revert();
    }

    /**
     * @dev Deposit from a sender.
     */
    function deposit() external override nonReentrant notRevoked payable {
        require(msg.value > 0, "Deposit amount should be greater than zero");

        _balance[msg.sender] = _balance[msg.sender] + msg.value;

        if(IGov(getGovAddress()).isMember(msg.sender)){
            uint256 minimum_staking = IEnvStorage(getEnvStorageAddress()).getStakingMin();
            if(minimum_staking > _lockedBalance[msg.sender] && availableBalanceOf(msg.sender) >= (minimum_staking - _lockedBalance[msg.sender]))
                _lock(msg.sender, minimum_staking - _lockedBalance[msg.sender]);
        }

        emit Staked(msg.sender, msg.value, _balance[msg.sender], availableBalanceOf(msg.sender));
    }

    /**
     * @dev Withdraw for a sender.
     * @param amount The amount of funds will be withdrawn and transferred to.
     */
    function withdraw(uint256 amount) external override nonReentrant notRevoked {
        require(amount > 0, "Amount should be bigger than zero");

        //if minimum is changed unlock staked value
        uint256 minimum_staking = IEnvStorage(getEnvStorageAddress()).getStakingMin();
        if(lockedBalanceOf(msg.sender) > minimum_staking){
            _unlock(msg.sender, lockedBalanceOf(msg.sender) - minimum_staking);
        }

        require(amount <= availableBalanceOf(msg.sender), "Withdraw amount should be equal or less than balance");

        _balance[msg.sender] = _balance[msg.sender] - amount;
        payable(msg.sender).transfer(amount);

        emit Unstaked(msg.sender, amount, _balance[msg.sender], availableBalanceOf(msg.sender));
    }

    /**
     * @dev Lock fund
     * @param payee The address whose funds will be locked.
     * @param lockAmount The amount of funds will be locked.
     */
    function lock(address payee, uint256 lockAmount) external override onlyGov {
        _lock(payee, lockAmount);
    }

    function lockMore(uint256 lockAmount) external onlyGovStaker {
        _lock(msg.sender, lockAmount);
    }

    function _lock(address payee, uint256 lockAmount) internal {
        if (lockAmount == 0) return;
        require(_balance[payee] >= lockAmount, "Lock amount should be equal or less than balance");
        require(availableBalanceOf(payee) >= lockAmount, "Insufficient balance that can be locked");
        uint256 maximum = IEnvStorage(getEnvStorageAddress()).getStakingMax();


        _lockedBalance[payee] = _lockedBalance[payee] + lockAmount;
        require(_lockedBalance[payee] <= maximum, "Locked balance is larger than max");

        _totalLockedBalance = _totalLockedBalance + lockAmount;

        emit Locked(payee, lockAmount, _balance[payee], availableBalanceOf(payee));
    }

    /**
     * @dev Transfer locked funds to governance
     * @param from The address whose funds will be transfered.
     * @param amount The amount of funds will be transfered.
     */
    function transferLocked(address from, uint256 amount) external override onlyGov {
        if (amount == 0) return;
        unlock(from, amount);
        _balance[from] = _balance[from] - amount;
        address rewardPool = getRewardPoolAddress();
        _balance[rewardPool] = _balance[rewardPool] + amount;

        emit TransferLocked(from, amount, _balance[from], availableBalanceOf(from));
    }

    /**
     * @dev Unlock fund
     * @param payee The address whose funds will be unlocked.
     * @param unlockAmount The amount of funds will be unlocked.
     */
    function unlock(address payee, uint256 unlockAmount) public override onlyGov {
        _unlock(payee, unlockAmount);
    }
    
    function _unlock(address payee, uint256 unlockAmount) internal {
        if (unlockAmount == 0) return;
        // require(_lockedBalance[payee] >= unlockAmount, "Unlock amount should be equal or less than balance locked");
        _lockedBalance[payee] = _lockedBalance[payee] - unlockAmount;
        _totalLockedBalance = _totalLockedBalance - unlockAmount;

        emit Unlocked(payee, unlockAmount, _balance[payee], availableBalanceOf(payee));
    }

    function balanceOf(address payee) public override view returns (uint256) {
        return _balance[payee];
    }

    function lockedBalanceOf(address payee) public override view returns (uint256) {
        return _lockedBalance[payee];
    }

    function availableBalanceOf(address payee) public override view returns (uint256) {
        return _balance[payee] - _lockedBalance[payee];
    }

    /**
     * @dev Calculate voting weight which range between 0 and 100.
     * @param payee The address whose funds were locked.
     */
    function calcVotingWeight(address payee) public override view returns (uint256) {
        return calcVotingWeightWithScaleFactor(payee, 1e2);
    }

    /**
     * @dev Calculate voting weight with a scale factor.
     * @param payee The address whose funds were locked.
     * @param factor The scale factor for weight. For instance:
     *               if 1e1, result range is between 0 ~ 10
     *               if 1e2, result range is between 0 ~ 100
     *               if 1e3, result range is between 0 ~ 1000
     */
    function calcVotingWeightWithScaleFactor(address payee, uint32 factor) public override view returns (uint256) {
        if (_lockedBalance[payee] == 0 || factor == 0) return 0;
        return _lockedBalance[payee] * factor / _totalLockedBalance;
    }

    function isRevoked() public view returns (bool) {
        return revoked;
    }

    modifier notRevoked(){
        require(!revoked, "Is revoked");
        _;
    }

    /**
     * @dev Allows the owner to revoke the staking. Funds already staked are returned to the owner
     */
    function revoke() public onlyOwner notRevoked {
        address contractOwner = owner();
        uint256 balance = address(this).balance;

        require(balance > 0, "balance = 0");

        payable(contractOwner).transfer(balance);
        revoked = true;

        emit Revoked(contractOwner, balance);
    }
}
