// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title DeoToken — DEO governance token (V1) with delegation checkpoints.
/// @notice UNIFIED-PLAN 1.7. Minimal ERC-20 (transfer/approve/transferFrom)
///         plus Compound-style delegation: voting power = delegated balance,
///         checkpointed per block. DeodesGovernance reads power ONLY via
///         getPriorVotes(account, proposalSnapshotBlock), so tokens acquired
///         after a proposal starts count for NOTHING (flash-loan defense).
///
///         Semantics (Compound-lite, documented for auditors):
///         - No delegation → no voting power (even with balance). Call
///           delegate(someone) — including delegate(self) — to activate.
///         - Transfers move power between the sender's and receiver's
///           CURRENT delegates at transfer time.
///         - getPriorVotes reverts for blockNumber >= current block
///           (power "not yet determined", exactly like Compound).
///         - Mint is owner-gated + hard-capped at 1B DEO. No burn in V1.
///         - Ownership moves to the governance timelock at 1.11; until then
///           mint is EOA-gated and every mint emits Transfer(0x0, to, amount).
contract DeoToken {
    string public constant name = "Deo";
    string public constant symbol = "DEO";
    uint8 public constant decimals = 18;
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;

    uint256 public totalSupply;
    address public owner;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => address) public delegates;

    struct Checkpoint {
        uint32 blockNumber;
        uint256 votes;
    }

    mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;
    mapping(address => uint32) public numCheckpoints;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed holder, address indexed spender, uint256 amount);
    event DelegateChanged(address indexed holder, address indexed from, address indexed to);
    event DelegateVotesChanged(address indexed delegatee, uint256 oldVotes, uint256 newVotes);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    error NotOwner();
    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();
    error SupplyCapped();
    error NotYetDetermined();

    constructor() {
        owner = msg.sender;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        _moveDelegates(delegates[msg.sender], delegates[to], amount);
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        if (allowance[from][msg.sender] < amount) revert InsufficientAllowance();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        _moveDelegates(delegates[from], delegates[to], amount);
        emit Transfer(from, to, amount);
        return true;
    }

    /// @notice Delegate voting power (including to self to self-activate).
    ///         Moves the holder's FULL current balance between representatives.
    function delegate(address to) external {
        if (to == address(0)) revert ZeroAddress();
        address current = delegates[msg.sender];
        delegates[msg.sender] = to;
        emit DelegateChanged(msg.sender, current, to);
        _moveDelegates(current, to, balanceOf[msg.sender]);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        if (to == address(0)) revert ZeroAddress();
        if (totalSupply + amount > MAX_SUPPLY) revert SupplyCapped();
        totalSupply += amount;
        balanceOf[to] += amount;
        _moveDelegates(address(0), delegates[to], amount);
        emit Transfer(address(0), to, amount);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert NotOwner();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /// @notice Voting power of account at the END of blockNumber. Reverts for
    ///         present/future blocks (Compound semantics).
    function getPriorVotes(address account, uint256 blockNumber) public view returns (uint256) {
        if (blockNumber >= block.number) revert NotYetDetermined();
        uint32 n = numCheckpoints[account];
        if (n == 0) return 0;
        if (checkpoints[account][n - 1].blockNumber <= blockNumber) {
            return checkpoints[account][n - 1].votes;
        }
        if (checkpoints[account][0].blockNumber > blockNumber) return 0;
        uint32 lo = 0;
        uint32 hi = n - 1;
        while (lo < hi) {
            uint32 mid = (lo + hi + 1) / 2;
            if (checkpoints[account][mid].blockNumber <= blockNumber) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return checkpoints[account][lo].votes;
    }

    function _moveDelegates(address srcRep, address dstRep, uint256 amount) internal {
        if (srcRep == dstRep || amount == 0) return;
        if (srcRep != address(0)) {
            uint32 n = numCheckpoints[srcRep];
            uint256 oldVotes = n > 0 ? checkpoints[srcRep][n - 1].votes : 0;
            uint256 updated = oldVotes - amount; // reverts on underflow: never fabricate
            _writeCheckpoint(srcRep, updated);
            emit DelegateVotesChanged(srcRep, oldVotes, updated);
        }
        if (dstRep != address(0)) {
            uint32 n = numCheckpoints[dstRep];
            uint256 oldVotes = n > 0 ? checkpoints[dstRep][n - 1].votes : 0;
            uint256 updated = oldVotes + amount;
            _writeCheckpoint(dstRep, updated);
            emit DelegateVotesChanged(dstRep, oldVotes, updated);
        }
    }

    function _writeCheckpoint(address delegatee, uint256 votes) internal {
        // LINT TRIAGE: `unsafe-typecast` on uint32(block.number) accepted —
        // checkpoints key on 32 bits (Compound-identical); Arc/test chains sit
        // at tens of millions of blocks, wrap-around needs ~4.29B.
        uint32 blk = uint32(block.number); // Arc/test chains: block counts far below 2^32
        uint32 n = numCheckpoints[delegatee];
        if (n > 0 && checkpoints[delegatee][n - 1].blockNumber == blk) {
            checkpoints[delegatee][n - 1].votes = votes;
        } else {
            checkpoints[delegatee][n] = Checkpoint(blk, votes);
            numCheckpoints[delegatee] = n + 1;
        }
    }
}
