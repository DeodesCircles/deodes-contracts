// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title DeodesCircle — minimal rotating savings circle (ROSCA) for Arc.
/// @notice V0 learning deployment for Arc TESTNET only. Members join with a
///         fixed USDC contribution (native gas token on Arc, 18 decimals);
///         each round exactly one unpaid member receives the pool minus a
///         0.5% protocol fee forwarded to `treasury`. Rotation without repeat
///         is enforced on-chain: a member can only be paid once per cycle.
contract DeodesCircle {
    uint256 public constant FEE_BPS = 50; // 0.5%

    address public immutable organizer;
    address public immutable treasury;
    uint256 public immutable contribution;
    uint256 public immutable maxMembers;
    uint256 public immutable createdAt;

    address[] public members;
    mapping(address => bool) public isMember;
    mapping(address => bool) public hasJoined;
    mapping(address => bool) public hasBeenPaid;
    uint256 public paidCount;
    uint256 public totalCollected;

    event Joined(address indexed member);
    event Contributed(address indexed member, uint256 amount);
    event PaidOut(address indexed recipient, uint256 net, uint256 fee);

    error NotOrganizer();
    error WrongContribution();
    error CircleFull();
    error AlreadyMember();
    error NotMember();
    error AlreadyPaid();
    error RotationComplete();
    error TransferFailed();

    constructor(
        address _treasury,
        uint256 _contribution,
        uint256 _maxMembers
    ) {
        require(_treasury != address(0), "treasury required");
        require(_contribution > 0, "contribution required");
        require(_maxMembers >= 2 && _maxMembers <= 100, "members 2-100");
        organizer = msg.sender;
        treasury = _treasury;
        contribution = _contribution;
        maxMembers = _maxMembers;
        createdAt = block.timestamp;
    }

    /// @notice Join with exactly `contribution` native USDC.
    function join() external payable {
        if (msg.value != contribution) revert WrongContribution();
        if (members.length >= maxMembers) revert CircleFull();
        if (hasJoined[msg.sender]) revert AlreadyMember();
        hasJoined[msg.sender] = true;
        isMember[msg.sender] = true;
        members.push(msg.sender);
        totalCollected += msg.value;
        emit Joined(msg.sender);
    }

    /// @notice Current round contribution (same fixed amount).
    function contribute() external payable {
        if (!isMember[msg.sender]) revert NotMember();
        if (msg.value != contribution) revert WrongContribution();
        totalCollected += msg.value;
        emit Contributed(msg.sender, msg.value);
    }

    /// @notice Pay one UNPAID member the pool minus the 0.5% fee. Anyone can
    ///         trigger; rotation-without-repeat is enforced, so the pool can
    ///         never go to the same member twice in one cycle.
    function payout(address recipient) external {
        if (!isMember[recipient]) revert NotMember();
        if (hasBeenPaid[recipient]) revert AlreadyPaid();
        if (paidCount >= members.length) revert RotationComplete();
        uint256 pool = address(this).balance;
        require(pool > 0, "empty pool");
        hasBeenPaid[recipient] = true;
        paidCount += 1;
        uint256 fee = (pool * FEE_BPS) / 10_000;
        uint256 net = pool - fee;
        (bool okFee, ) = treasury.call{value: fee}("");
        if (!okFee) revert TransferFailed();
        (bool ok, ) = recipient.call{value: net}("");
        if (!ok) revert TransferFailed();
        totalCollected = 0;
        emit PaidOut(recipient, net, fee);
    }

    function memberCount() external view returns (uint256) {
        return members.length;
    }

    function unpaidCount() external view returns (uint256) {
        return members.length - paidCount;
    }
}
