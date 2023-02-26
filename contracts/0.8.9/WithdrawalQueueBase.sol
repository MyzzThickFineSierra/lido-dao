// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

/* See contracts/COMPILERS.md */
pragma solidity 0.8.9;

import "@openzeppelin/contracts-v4.4/utils/structs/EnumerableSet.sol";
import {UnstructuredStorage} from "./lib/UnstructuredStorage.sol";
import {UnstructuredRefStorage} from "./lib/UnstructuredRefStorage.sol";
import {Math} from "./lib/Math.sol";

/// @title Queue to store and manage WithdrawalRequests.
/// @dev Use an optimizations to store discounts heavily inspired
/// by Aragon MiniMe token https://github.com/aragon/aragon-minime/blob/master/contracts/MiniMeToken.sol
///
/// @author folkyatina
abstract contract WithdrawalQueueBase {
    using EnumerableSet for EnumerableSet.UintSet;
    using UnstructuredStorage for bytes32;
    using UnstructuredRefStorage for bytes32;

    /// @notice precision base for share rate and discounting factor values in the contract
    uint256 public constant E27_PRECISION_BASE = 1e27;

    uint256 public constant MAX_NUMBER_OF_BATCHES = 36;
    uint256 public constant MAX_REQUESTS_PER_CALL = 1000;

    uint256 internal constant SHARE_RATE_UNLIMITED = type(uint256).max;

    /// @dev return value for the `find...` methods in case of no result
    uint256 internal constant NOT_FOUND = 0;

    // queue for withdrawal requests, indexes (requestId) start from 1
    bytes32 internal constant QUEUE_POSITION = keccak256("lido.WithdrawalQueue.queue");
    // length of the queue
    bytes32 internal constant LAST_REQUEST_ID_POSITION = keccak256("lido.WithdrawalQueue.lastRequestId");
    // length of the finalized part of the queue. Always <= `requestCounter`
    bytes32 internal constant LAST_FINALIZED_REQUEST_ID_POSITION =
        keccak256("lido.WithdrawalQueue.lastFinalizedRequestId");
    /// finalization discount history, indexes start from 1
    bytes32 internal constant CHECKPOINTS_POSITION = keccak256("lido.WithdrawalQueue.checkpoints");
    /// length of the checkpoints
    bytes32 internal constant LAST_CHECKPOINT_INDEX_POSITION = keccak256("lido.WithdrawalQueue.lastCheckpointIndex");
    /// amount of eth locked on contract for withdrawal
    bytes32 internal constant LOCKED_ETHER_AMOUNT_POSITION = keccak256("lido.WithdrawalQueue.lockedEtherAmount");
    /// withdrawal requests mapped to the owners
    bytes32 internal constant REQUEST_BY_OWNER_POSITION = keccak256("lido.WithdrawalQueue.requestsByOwner");
    /// list of extremum requests for shareRate(request_id) function
    bytes32 internal constant EXTREMA_POSITION = keccak256("lido.WithdrawalQueue.extremumRequestId");

    /// @notice structure representing a request for withdrawal.
    struct WithdrawalRequest {
        /// @notice sum of the all stETH submitted for withdrawals up to this request
        uint128 cumulativeStETH;
        /// @notice sum of the all shares locked for withdrawal up to this request
        uint128 cumulativeShares;
        /// @notice address that can claim or transfer the request
        address owner;
        /// @notice block.timestamp when the request was created
        uint64 timestamp;
        /// @notice flag if the request was claimed
        bool claimed;
    }

    /// @notice structure to store discounts for requests that are affected by negative rebase
    struct Checkpoint {
        uint256 fromRequestId;
        uint256 maxShareRate;
    }

    /// @notice output format struct for `_getWithdrawalStatus()` method
    struct WithdrawalRequestStatus {
        /// @notice stETH token amount that was locked on withdrawal queue for this request
        uint256 amountOfStETH;
        /// @notice amount of stETH shares locked on withdrawal queue for this request
        uint256 amountOfShares;
        /// @notice address that can claim or transfer this request
        address owner;
        /// @notice timestamp of when the request was created, in seconds
        uint256 timestamp;
        /// @notice true, if request is finalized
        bool isFinalized;
        /// @notice true, if request is claimed. Request is claimable if (isFinalized && !isClaimed)
        bool isClaimed;
    }

    /// @dev Contains both stETH token amount and its corresponding shares amount
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed requestor,
        address indexed owner,
        uint256 amountOfStETH,
        uint256 amountOfShares
    );
    event WithdrawalBatchFinalized(
        uint256 indexed from, uint256 indexed to, uint256 amountOfETHLocked, uint256 sharesToBurn, uint256 timestamp
    );
    event WithdrawalClaimed(
        uint256 indexed requestId, address indexed owner, address indexed receiver, uint256 amountOfETH
    );

    error ZeroAmountOfETH();
    error ZeroShareRate();
    error ZeroTimestamp();
    error TooMuchEtherToFinalize(uint256 sent, uint256 maxExpected);
    error NotOwner(address _sender, address _owner);
    error InvalidRequestId(uint256 _requestId);
    error InvalidRequestIdRange(uint256 startId, uint256 endId);
    error InvalidState();
    error EmptyBatches();
    error RequestNotFoundOrNotFinalized(uint256 _requestId);
    error NotEnoughEther();
    error RequestAlreadyClaimed(uint256 _requestId);
    error InvalidHint(uint256 _hint);
    error CantSendValueRecipientMayHaveReverted();

    /// @notice id of the last request, returns 0, if no request in the queue
    function getLastRequestId() public view returns (uint256) {
        return LAST_REQUEST_ID_POSITION.getStorageUint256();
    }

    /// @notice id of the last finalized request, returns 0 if no finalized requests in the queue
    function getLastFinalizedRequestId() public view returns (uint256) {
        return LAST_FINALIZED_REQUEST_ID_POSITION.getStorageUint256();
    }

    /// @notice amount of ETH on this contract balance that is locked for withdrawal and available to claim
    function getLockedEtherAmount() public view returns (uint256) {
        return LOCKED_ETHER_AMOUNT_POSITION.getStorageUint256();
    }

    /// @notice length of the checkpoints. Last possible value for the claim hint
    function getLastCheckpointIndex() public view returns (uint256) {
        return LAST_CHECKPOINT_INDEX_POSITION.getStorageUint256();
    }

    /// @notice return the number of unfinalized requests in the queue
    function unfinalizedRequestNumber() external view returns (uint256) {
        return getLastRequestId() - getLastFinalizedRequestId();
    }

    /// @notice Returns the amount of stETH in the queue yet to be finalized
    function unfinalizedStETH() external view returns (uint256) {
        return
            _getQueue()[getLastRequestId()].cumulativeStETH - _getQueue()[getLastFinalizedRequestId()].cumulativeStETH;
    }

    // FINALIZATION.
    // Process when protocol is fixing the withdrawal request value and lock the required amount of stETH.
    // It is driven by the oracle report
    // Right now finalization consists of several steps:
    // 1. Oracle daemon precalculates finalization batches' boundaries that is valid on oracle report refSlot
    //  and post it with the report - `calculateFinalizationBatches()`
    // 2. Lido contract invokes `onPreRebase()` handler to update ShareRate extremum list
    // 3. Lido contract, during the report handling, calculates the value of finalization batchs in eth and shares
    //  and checks its correctness - `finalizationValue()`
    // 4. Lido contract finalize the requests pasing the required ether along with `finalize()` method

    struct CalcState {
        uint256 ethBudget;
        bool finished;
        uint256[] batches;
    }

    function calculateFinalizationBatches(uint256 _maxShareRate, uint256 _maxTimestamp, CalcState memory _state)
        external
        view
        returns (CalcState memory)
    {
        if (_state.finished) revert InvalidState();

        uint256 requestId;
        uint256 prevRequestShareRate;

        if (_state.batches.length == 0) {
            requestId = getLastFinalizedRequestId() + 1;
            // we'll store batches as a array where [MAX_NUMBER_OF_BATCHES] element is the array's length
            _state.batches = new uint256[](MAX_NUMBER_OF_BATCHES + 1);
        } else {
            uint256 prevIterationEndId = _state.batches[_state.batches[0]];
            requestId = prevIterationEndId + 1;
            prevRequestShareRate = _calcShareRate(prevIterationEndId, _maxShareRate);
        }

        uint256 length = _state.batches[MAX_NUMBER_OF_BATCHES];

        uint256 lastRequestId = getLastRequestId();
        uint256 postFinalId = Math.min(requestId + MAX_REQUESTS_PER_CALL, lastRequestId + 1);

        while (requestId < postFinalId) {
            WithdrawalRequest memory request = _getQueue()[requestId];

            if (request.timestamp > _maxTimestamp) break;

            WithdrawalRequest memory prevRequest = _getQueue()[requestId - 1];

            (uint256 requestShareRate, uint256 etherRequested) =
                _calcShareRateAndEth(prevRequest, request, _maxShareRate);
            if (etherRequested > _state.ethBudget) break;

            _state.ethBudget -= etherRequested;

            if (length != 0 && (
                prevRequestShareRate < _maxShareRate && requestShareRate < _maxShareRate ||
                prevRequestShareRate >= _maxShareRate && requestShareRate >= _maxShareRate
            )) {
                _state.batches[length - 1] = requestId;
            } else {
                if (length == MAX_NUMBER_OF_BATCHES) break;
                _state.batches[length] = requestId;
                ++length;
            }

            prevRequestShareRate = requestShareRate;
            ++requestId;
        }

        _state.finished = requestId < postFinalId || requestId == lastRequestId + 1;

        if (_state.finished) {
            // TODO: trim array in memory
            uint256[] memory result = new uint256[](length);
            for (uint256 i = 0; i < length; ++i) {
                result[i] = _state.batches[i];
            }
             _state.batches = result;
        } else {
            _state.batches[MAX_NUMBER_OF_BATCHES] = length;
        }

        return _state;
    }

    function onPreRebase() external {
        // Populate shareRate extrema array
        // Invariants:
        // • shareRate(extrema[0]) == shareRate(queue[1])
        // • shareRate(extrema[n]) != shareRate(extrema[n+1])
        // • extrema[last] is minimum => shareRate(lastRequestId) <= shareRate(lastRequestId)
        // • extrema[last] is maximum => shareRate(lastRequestId) >= shareRate(lastRequestId)
        uint256 lastRequestId = getLastRequestId();
        uint256[] storage extrema = _getExtrema();
        // first request is an extremum
        if (extrema.length == 0 && lastRequestId > 0) {
            extrema.push(lastRequestId);
        }

        uint256 lastExtremumId = extrema[extrema.length - 1];

        if (lastRequestId > lastExtremumId) {
            uint256 lastRequestShareRate = _calcShareRate(lastRequestId);
            uint256 lastExtremumShareRate = _calcShareRate(lastExtremumId);

            if (lastRequestShareRate == lastExtremumShareRate) return;
            // first met request in a sequence with equal shareRate is an extremum

            if (extrema.length == 1) {
                // first two different rates are always extrema
                extrema.push(lastRequestId);
            } else {
                uint256 prevExtremumShareRate = _calcShareRate(lastExtremumId - 1);

                bool wasGrowing = lastExtremumShareRate > prevExtremumShareRate;
                // |  •
                // |•   *
                // +------->
                if (wasGrowing && lastRequestShareRate < lastExtremumShareRate) {
                    extrema.push(lastRequestId);
                    return;
                }
                // |•   *
                // |  •
                // +------->
                if (!wasGrowing && lastRequestShareRate > lastExtremumShareRate) {
                    extrema.push(lastRequestId);
                    return;
                }
            }
        }
    }

    function finalizationValue(uint256[] calldata _batches, uint256 _maxShareRate)
        public
        view
        returns (uint256 ethToLock, uint256 sharesToBurn)
    {
        if (_maxShareRate == 0) revert ZeroShareRate();
        _checkFinalizationBatchesIntegrity(_batches);

        uint256 preBatchStartId = getLastFinalizedRequestId();
        uint256 batchIndex;

        do {
            WithdrawalRequest memory batchStart = _getQueue()[preBatchStartId];
            WithdrawalRequest memory batchEnd = _getQueue()[_batches[batchIndex]];

            uint256 shares = batchEnd.cumulativeShares - batchStart.cumulativeShares;
            uint256 eth = batchEnd.cumulativeStETH - batchStart.cumulativeStETH;

            uint256 batchShareRate = (eth * E27_PRECISION_BASE) / shares;
            if (batchShareRate > _maxShareRate) {
                ethToLock += shares * _maxShareRate / E27_PRECISION_BASE;
            } else {
                ethToLock += eth;
            }

            sharesToBurn += shares;

            preBatchStartId = _batches[batchIndex];
            ++batchIndex;
        } while (batchIndex < _batches.length);
    }

    function _checkFinalizationBatchesIntegrity(uint256[] memory _batches) internal view {
        if (_batches.length == 0) revert EmptyBatches();
        uint256 lastIdInBatch = _batches[_batches.length - 1];
        if (lastIdInBatch > getLastRequestId()) revert InvalidRequestId(lastIdInBatch);
        uint256 lastFinalizedRequestId = getLastFinalizedRequestId();
        uint256 firstIdInBatch = _batches[0];
        if (firstIdInBatch <= lastFinalizedRequestId) revert InvalidRequestId(firstIdInBatch);

        // TODO: check extrema and crossing points
    }

    /// @dev Finalize requests from last finalized one up to `_nextFinalizedRequestId`
    ///  Emits WithdrawalBatchFinalized event.
    function _finalize(uint256 _nextFinalizedRequestId, uint256 _amountOfETH, uint256 _maxShareRate) internal {
        if (_nextFinalizedRequestId > getLastRequestId()) revert InvalidRequestId(_nextFinalizedRequestId);
        uint256 lastFinalizedRequestId = getLastFinalizedRequestId();
        uint256 firstUnfinalizedRequestId = lastFinalizedRequestId + 1;
        if (_nextFinalizedRequestId <= lastFinalizedRequestId) revert InvalidRequestId(_nextFinalizedRequestId);

        WithdrawalRequest memory lastFinalizedRequest = _getQueue()[lastFinalizedRequestId];
        WithdrawalRequest memory requestToFinalize = _getQueue()[_nextFinalizedRequestId];

        uint128 stETHToFinalize = requestToFinalize.cumulativeStETH - lastFinalizedRequest.cumulativeStETH;
        if (_amountOfETH > stETHToFinalize) revert TooMuchEtherToFinalize(_amountOfETH, stETHToFinalize);

        uint256 maxShareRate = SHARE_RATE_UNLIMITED;
        if (stETHToFinalize > _amountOfETH) {
            maxShareRate = _maxShareRate;
        }

        uint256 lastCheckpointIndex = getLastCheckpointIndex();
        Checkpoint storage lastCheckpoint = _getCheckpoints()[lastCheckpointIndex];

        if (maxShareRate != lastCheckpoint.maxShareRate) {
            // add a new discount if it differs from the previous
            _getCheckpoints()[lastCheckpointIndex + 1] = Checkpoint(firstUnfinalizedRequestId, maxShareRate);
            _setLastCheckpointIndex(lastCheckpointIndex + 1);
        }

        _setLockedEtherAmount(getLockedEtherAmount() + _amountOfETH);
        _setLastFinalizedRequestId(_nextFinalizedRequestId);

        emit WithdrawalBatchFinalized(
            firstUnfinalizedRequestId,
            _nextFinalizedRequestId,
            _amountOfETH,
            requestToFinalize.cumulativeShares - lastFinalizedRequest.cumulativeShares,
            block.timestamp
            );
    }

    /// @dev creates a new `WithdrawalRequest` in the queue
    ///  Emits WithdrawalRequested event
    /// Does not check parameters
    function _enqueue(uint128 _amountOfStETH, uint128 _amountOfShares, address _owner)
        internal
        returns (uint256 requestId)
    {
        uint256 lastRequestId = getLastRequestId();
        WithdrawalRequest memory lastRequest = _getQueue()[lastRequestId];

        uint128 cumulativeShares = lastRequest.cumulativeShares + _amountOfShares;
        uint128 cumulativeStETH = lastRequest.cumulativeStETH + _amountOfStETH;

        requestId = lastRequestId + 1;

        _setLastRequestId(requestId);
        _getQueue()[requestId] =
            WithdrawalRequest(cumulativeStETH, cumulativeShares, _owner, uint64(block.timestamp), false);
        assert(_getRequestsByOwner()[_owner].add(requestId));

        emit WithdrawalRequested(requestId, msg.sender, _owner, _amountOfStETH, _amountOfShares);
    }

    /// @notice Returns status of the withdrawal request with `_requestId` id
    function _getStatus(uint256 _requestId) internal view returns (WithdrawalRequestStatus memory status) {
        if (_requestId == 0 || _requestId > getLastRequestId()) revert InvalidRequestId(_requestId);

        WithdrawalRequest memory request = _getQueue()[_requestId];
        WithdrawalRequest memory previousRequest = _getQueue()[_requestId - 1];

        status = WithdrawalRequestStatus(
            request.cumulativeStETH - previousRequest.cumulativeStETH,
            request.cumulativeShares - previousRequest.cumulativeShares,
            request.owner,
            request.timestamp,
            _requestId <= getLastFinalizedRequestId(),
            request.claimed
        );
    }

    /// @notice View function to find a checkpoint hint for `claimWithdrawal()`
    ///  Search will be performed in the range of `[_firstIndex, _lastIndex]`
    ///
    /// NB!: Range search ought to be used to optimize gas cost.
    /// You can utilize the following invariant:
    /// `if (requestId2 > requestId1) than hint2 >= hint1`,
    /// so you can search for `hint2` in the range starting from `hint1`
    ///
    /// @param _requestId request id we are searching the checkpoint for
    /// @param _start index of the left boundary of the search range
    /// @param _end index of the right boundary of the search range
    ///
    /// @return value that hints `claimWithdrawal` to find the discount for the request,
    ///  or 0 if hint not found in the range
    function _findCheckpointHint(uint256 _requestId, uint256 _start, uint256 _end) internal view returns (uint256) {
        if (_requestId == 0) revert InvalidRequestId(_requestId);
        if (_start == 0) revert InvalidRequestIdRange(_start, _end);
        uint256 lastCheckpointIndex = getLastCheckpointIndex();
        if (_end > lastCheckpointIndex) revert InvalidRequestIdRange(_start, _end);
        if (_requestId > getLastFinalizedRequestId()) revert RequestNotFoundOrNotFinalized(_requestId);

        if (_start > _end) return NOT_FOUND; // we have an empty range to search in, so return NOT_FOUND

        // Right boundary
        if (_requestId >= _getCheckpoints()[_end].fromRequestId) {
            // it's the last checkpoint, so it's valid
            if (_end == lastCheckpointIndex) return _end;
            // it fits right before the next checkpoint
            if (_requestId < _getCheckpoints()[_end + 1].fromRequestId) return _end;

            return NOT_FOUND;
        }
        // Left boundary
        if (_requestId < _getCheckpoints()[_start].fromRequestId) {
            return NOT_FOUND;
        }

        // Binary search
        uint256 min = _start;
        uint256 max = _end - 1;

        while (max > min) {
            uint256 mid = (max + min + 1) / 2;
            if (_getCheckpoints()[mid].fromRequestId <= _requestId) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    /// @notice Claim `_requestId` request and transfer locked ether to `_recipient`. Emits WithdrawalClaimed event
    /// @param _requestId request id to claim
    /// @param _hint hint for discount checkpoint index to avoid extensive search over the checkpoints.
    /// @param _recipient address to send ether to
    function _claim(uint256 _requestId, uint256 _hint, address _recipient) internal {
        if (_requestId == 0) revert InvalidRequestId(_requestId);
        if (_requestId > getLastFinalizedRequestId()) revert RequestNotFoundOrNotFinalized(_requestId);

        WithdrawalRequest storage request = _getQueue()[_requestId];

        if (request.claimed) revert RequestAlreadyClaimed(_requestId);
        if (request.owner != msg.sender) revert NotOwner(msg.sender, request.owner);

        request.claimed = true;
        assert(_getRequestsByOwner()[request.owner].remove(_requestId));

        uint256 ethWithDiscount = _calculateClaimableEther(request, _requestId, _hint);

        _setLockedEtherAmount(getLockedEtherAmount() - ethWithDiscount);
        _sendValue(payable(_recipient), ethWithDiscount);

        emit WithdrawalClaimed(_requestId, msg.sender, _recipient, ethWithDiscount);
    }

    /// @notice Calculates discounted ether value for `_requestId` using a provided `_hint`. Checks if hint is valid
    /// @return claimableEther discounted eth for `_requestId`. Returns 0 if request is not claimable
    function _calculateClaimableEther(WithdrawalRequest storage _request, uint256 _requestId, uint256 _hint)
        internal
        view
        returns (uint256 claimableEther)
    {
        if (_hint == 0) revert InvalidHint(_hint);

        uint256 lastCheckpointIndex = getLastCheckpointIndex();
        if (_hint > lastCheckpointIndex) revert InvalidHint(_hint);

        Checkpoint memory checkpoint = _getCheckpoints()[_hint];
        // ______(>______
        //    ^  hint
        if (_requestId < checkpoint.fromRequestId) revert InvalidHint(_hint);
        if (_hint < lastCheckpointIndex) {
            // ______(>______(>________
            //       hint    hint+1  ^
            Checkpoint memory nextCheckpoint = _getCheckpoints()[_hint + 1];
            if (nextCheckpoint.fromRequestId <= _requestId) {
                revert InvalidHint(_hint);
            }
        }

        WithdrawalRequest memory prevRequest = _getQueue()[_requestId - 1];

        uint256 ethRequested = _request.cumulativeStETH - prevRequest.cumulativeStETH;
        uint256 shareRequested = _request.cumulativeShares - prevRequest.cumulativeShares;

        if (ethRequested * E27_PRECISION_BASE / shareRequested <= checkpoint.maxShareRate) {
            return ethRequested;
        }

        return shareRequested * checkpoint.maxShareRate / E27_PRECISION_BASE;
    }

    // quazi-constructor
    function _initializeQueue() internal {
        // setting dummy zero structs in checkpoints and queue beginning
        // to avoid uint underflows and related if-branches
        // 0-index is reserved as 'not_found' response in the interface everywhere
        _getQueue()[0] = WithdrawalRequest(0, 0, address(0), uint64(block.number), true);
        _getCheckpoints()[getLastCheckpointIndex()] = Checkpoint(0, 0);
    }

    function _sendValue(address _recipient, uint256 _amount) internal {
        if (address(this).balance < _amount) revert NotEnoughEther();

        // solhint-disable-next-line
        (bool success,) = _recipient.call{value: _amount}("");
        if (!success) revert CantSendValueRecipientMayHaveReverted();
    }

    function _calcShareRateAndEth(
        WithdrawalRequest memory _prevRequest,
        WithdrawalRequest memory _lastRequest,
        uint256 maxShareRate
    ) internal pure returns (uint256 eth, uint256 shares) {
        uint256 ethRequested = _lastRequest.cumulativeStETH - _prevRequest.cumulativeStETH;
        uint256 shareRequested = _lastRequest.cumulativeShares - _prevRequest.cumulativeShares;

        if (ethRequested * E27_PRECISION_BASE / shareRequested <= maxShareRate) {
            return (ethRequested, shareRequested);
        }

        return (shareRequested * maxShareRate / E27_PRECISION_BASE, shareRequested);
    }

    function _calcShareRate(uint256 _requestId, uint256 _maxShareRate) internal view returns (uint256) {
        WithdrawalRequest memory prevRequest = _getQueue()[_requestId - 1];
        WithdrawalRequest memory lastRequest = _getQueue()[_requestId];

        uint256 ethRequested = lastRequest.cumulativeStETH - prevRequest.cumulativeStETH;
        uint256 shareRequested = lastRequest.cumulativeShares - prevRequest.cumulativeShares;

        return Math.min(ethRequested * E27_PRECISION_BASE / shareRequested, _maxShareRate);
    }

    function _calcShareRate(uint256 _requestId) internal view returns (uint256) {
        return _calcShareRate(_requestId, SHARE_RATE_UNLIMITED);
    }

    //
    // Internal getters and setters
    //
    function _getQueue() internal pure returns (mapping(uint256 => WithdrawalRequest) storage queue) {
        bytes32 position = QUEUE_POSITION;
        assembly {
            queue.slot := position
        }
    }

    function _getCheckpoints() internal pure returns (mapping(uint256 => Checkpoint) storage checkpoints) {
        bytes32 position = CHECKPOINTS_POSITION;
        assembly {
            checkpoints.slot := position
        }
    }

    function _getRequestsByOwner()
        internal
        pure
        returns (mapping(address => EnumerableSet.UintSet) storage requestsByOwner)
    {
        bytes32 position = REQUEST_BY_OWNER_POSITION;
        assembly {
            requestsByOwner.slot := position
        }
    }

    function _getExtrema() internal pure returns (uint256[] storage) {
        return EXTREMA_POSITION.storageUint256Array();
    }

    function _setLastRequestId(uint256 _lastRequestId) internal {
        LAST_REQUEST_ID_POSITION.setStorageUint256(_lastRequestId);
    }

    function _setLastFinalizedRequestId(uint256 _lastFinalizedRequestId) internal {
        LAST_FINALIZED_REQUEST_ID_POSITION.setStorageUint256(_lastFinalizedRequestId);
    }

    function _setLastCheckpointIndex(uint256 _lastCheckpointIndex) internal {
        LAST_CHECKPOINT_INDEX_POSITION.setStorageUint256(_lastCheckpointIndex);
    }

    function _setLockedEtherAmount(uint256 _lockedEtherAmount) internal {
        LOCKED_ETHER_AMOUNT_POSITION.setStorageUint256(_lockedEtherAmount);
    }
}
