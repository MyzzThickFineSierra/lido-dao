pragma solidity 0.4.24;

import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/lib/math/SafeMath.sol";
import "@aragon/os/contracts/lib/math/SafeMath64.sol";
import "@aragon/os/contracts/common/IsContract.sol";
import "solidity-bytes-utils/contracts/BytesLib.sol";

import "@depools/dao/contracts/interfaces/IDePool.sol";
import "@depools/dao/contracts/interfaces/ISTETH.sol";
import "@depools/dao/contracts/interfaces/IValidatorRegistration.sol";
import "@depools/depool-lib/contracts/Pausable.sol";


/**
  * @title Liquid staking pool implementation
  *
  * See the comment of `IDePool`.
  *
  * NOTE: the code below assumes moderate amount of staking providers, e.g. up to 50.
  */
contract DePool is IDePool, IsContract, Pausable, AragonApp {
    using SafeMath for uint256;
    using SafeMath64 for uint64;
    using UnstructuredStorage for bytes32;

    /// ACL
    bytes32 constant public PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 constant public MANAGE_FEE = keccak256("MANAGE_FEE");
    bytes32 constant public MANAGE_WITHDRAWAL_KEY = keccak256("MANAGE_WITHDRAWAL_KEY");
    bytes32 constant public MANAGE_SIGNING_KEYS = keccak256("MANAGE_SIGNING_KEYS");
    bytes32 constant public SET_ORACLE = keccak256("SET_ORACLE");
    bytes32 constant public ADD_STAKING_PROVIDER_ROLE = keccak256("ADD_STAKING_PROVIDER_ROLE");
    bytes32 constant public SET_STAKING_PROVIDER_ACTIVE_ROLE = keccak256("SET_STAKING_PROVIDER_ACTIVE_ROLE");
    bytes32 constant public SET_STAKING_PROVIDER_NAME_ROLE = keccak256("SET_STAKING_PROVIDER_NAME_ROLE");
    bytes32 constant public SET_STAKING_PROVIDER_ADDRESS_ROLE = keccak256("SET_STAKING_PROVIDER_ADDRESS_ROLE");
    bytes32 constant public SET_STAKING_PROVIDER_LIMIT_ROLE = keccak256("SET_STAKING_PROVIDER_LIMIT_ROLE");
    bytes32 constant public REPORT_STOPPED_VALIDATORS_ROLE = keccak256("REPORT_STOPPED_VALIDATORS_ROLE");

    uint256 constant public PUBKEY_LENGTH = 48;
    uint256 constant public WITHDRAWAL_CREDENTIALS_LENGTH = 32;
    uint256 constant public SIGNATURE_LENGTH = 96;

    uint256 constant public DEPOSIT_SIZE = 32 ether;

    uint256 internal constant MIN_DEPOSIT_AMOUNT = 1 ether;     // validator_registration.vy
    uint256 internal constant DEPOSIT_AMOUNT_UNIT = 1000000000 wei;     // validator_registration.vy

    bytes32 internal constant FEE_VALUE_POSITION = keccak256("depools.DePool.fee");
    bytes32 internal constant TREASURY_FEE_VALUE_POSITION = keccak256("depools.DePool.treasuryFee");
    bytes32 internal constant INSURANCE_FEE_VALUE_POSITION = keccak256("depools.DePool.insuranceFee");
    bytes32 internal constant SP_FEE_VALUE_POSITION = keccak256("depools.DePool.SPFee");

    bytes32 internal constant TOKEN_VALUE_POSITION = keccak256("depools.DePool.token");
    bytes32 internal constant VALIDATOR_REGISTRATION_VALUE_POSITION = keccak256("depools.DePool.validatorRegistration");
    bytes32 internal constant ORACLE_VALUE_POSITION = keccak256("depools.DePool.oracle");

    /// @dev A base value for tracking earned rewards
    bytes32 internal constant REWARD_BASE_VALUE_POSITION = keccak256("depools.DePool.rewardBase");

    /// @dev amount of Ether (on the current Ethereum side) buffered on this smart contract balance
    bytes32 internal constant BUFFERED_ETHER_VALUE_POSITION = keccak256("depools.DePool.bufferedEther");
    /// @dev amount of Ether (on the current Ethereum side) deposited to the validator_registration.vy contract
    bytes32 internal constant DEPOSITED_ETHER_VALUE_POSITION = keccak256("depools.DePool.depositedEther");
    /// @dev amount of Ether (on the Ethereum 2.0 side) managed by the system
    bytes32 internal constant REMOTE_ETHER2_VALUE_POSITION = keccak256("depools.DePool.remoteEther2");

    /// @dev last epoch reported by the oracle
    bytes32 internal constant LAST_ORACLE_EPOCH_VALUE_POSITION = keccak256("depools.DePool.lastOracleEpoch");

    bytes32 internal constant SIGNING_KEYS_MAPPING_NAME = keccak256("depools.DePool.signingKeys");


    /// @dev Credentials which allows the DAO to withdraw Ether on the 2.0 side
    bytes private withdrawalCredentials;


    /// @dev Request to withdraw Ether on the 2.0 side
    struct WithdrawalRequest {
        uint256 amount;     // amount of wei to withdraw on the 2.0 side
        bytes32 pubkeyHash; // receiver's public key hash
    }

    /// @dev Queue of withdrawal requests
    WithdrawalRequest[] internal withdrawalRequests;


    /// @dev Staking provider parameters and internal state
    struct StakingProvider {
        bool active;    // a flag indicating if the SP can participate in further staking and reward distribution
        address rewardAddress;  // Ethereum 1 address which receives steth rewards for this SP
        string name;    // human-readable name
        uint64 stakingLimit;    // the maximum number of validators to stake for this SP
        uint64 stoppedValidators;   // number of signing keys which stopped validation (e.g. were slashed)

        uint64 totalSigningKeys;    // total amount of signing keys of this SP
        uint64 usedSigningKeys;     // number of signing keys of this SP which were used in deposits to the Ethereum 2
    }

    /// @dev Array of all staking providers
    StakingProvider[] internal sps;

    // @dev Cached number of active SPs
    uint256 internal activeSPCount;


    // Memory cache entry used in the _ETH2Deposit function
    struct DepositLookupCacheEntry {
        // Makes no sense to pack types since reading memory is as fast as any op
        uint256 id;
        uint256 stakingLimit;
        uint256 stoppedValidators;
        uint256 totalSigningKeys;
        uint256 usedSigningKeys;
        uint256 initialUsedSigningKeys; // for write-back control
    }


    modifier validAddress(address _a) {
        require(_a != address(0), "EMPTY_ADDRESS");
        _;
    }

    modifier SPExists(uint256 _id) {
        require(0 != _id && _id < sps.length, "STAKING_PROVIDER_NOT_FOUND");
        _;
    }


    function initialize(ISTETH _token, IValidatorRegistration validatorRegistration, address _oracle) public onlyInit {
        _setToken(_token);
        _setValidatorRegistrationContract(validatorRegistration);
        _setOracle(_oracle);

        sps.length++;    // sp[0] is unused
        activeSPCount = 0;

        initialized();
    }


    /**
      * @notice Adds eth to the pool
      */
    function() external payable {
        _submit(0);
    }

    /**
      * @notice Adds eth to the pool with optional _referral parameter
      * @return StETH Amount of StETH generated
      */
    function submit(address _referral) external payable returns (uint256 StETH) {
        return _submit(_referral);
    }


    /**
      * @notice Stop pool routine operations
      */
    function stop() external auth(PAUSE_ROLE) {
        _stop();
    }

    /**
      * @notice Resume pool routine operations
      */
    function resume() external auth(PAUSE_ROLE) {
        _resume();
    }


    /**
      * @notice Set fee rate to `_feeBasisPoints` basis points. The fees are accrued when oracles report staking results
      * @param _feeBasisPoints Fee rate, in basis points
      */
    function setFee(uint16 _feeBasisPoints) external auth(MANAGE_FEE) {
        _setBPValue(FEE_VALUE_POSITION, _feeBasisPoints);
        emit FeeSet(_feeBasisPoints);
    }

    /**
      * @notice Set fee distribution: `_treasuryFeeBasisPoints` basis points go to the treasury, `_insuranceFeeBasisPoints` basis points go to the insurance fund, `_SPFeeBasisPoints` basis points go to staking providers. The sum has to be 10 000.
      */
    function setFeeDistribution(uint16 _treasuryFeeBasisPoints, uint16 _insuranceFeeBasisPoints,
                                uint16 _SPFeeBasisPoints) external auth(MANAGE_FEE)
    {
        require(10000 == uint256(_treasuryFeeBasisPoints).add(uint256(_insuranceFeeBasisPoints)).add(uint256(_SPFeeBasisPoints)),
                "FEES_DONT_ADD_UP");

        _setBPValue(TREASURY_FEE_VALUE_POSITION, _treasuryFeeBasisPoints);
        _setBPValue(INSURANCE_FEE_VALUE_POSITION, _insuranceFeeBasisPoints);
        _setBPValue(SP_FEE_VALUE_POSITION, _SPFeeBasisPoints);

        emit FeeDistributionSet(_treasuryFeeBasisPoints, _insuranceFeeBasisPoints, _SPFeeBasisPoints);
    }

    /**
      * @notice Set authorized oracle address to `_oracle`
      */
    function setOracle(address _oracle) external auth(SET_ORACLE) {
        _setOracle(_oracle);
    }


    /**
      * @notice Set credentials to withdraw ETH on ETH 2.0 side after the phase 2 is launched to `_withdrawalCredentials`
      * @dev Note that setWithdrawalCredentials discards all unused signing keys as the signatures are invalidated.
      * @param _withdrawalCredentials hash of withdrawal multisignature key as accepted by
      *        the validator_registration.deposit function
      */
    function setWithdrawalCredentials(bytes _withdrawalCredentials) external auth(MANAGE_WITHDRAWAL_KEY) {
        require(_withdrawalCredentials.length == WITHDRAWAL_CREDENTIALS_LENGTH, "INVALID_LENGTH");

        withdrawalCredentials = _withdrawalCredentials;

        uint256 length = sps.length;
        for (uint256 SP_id = 1; SP_id < length; ++SP_id) {
            if (sps[SP_id].totalSigningKeys != sps[SP_id].usedSigningKeys)    // write only if update is needed
                // discard unused keys
                sps[SP_id].totalSigningKeys = sps[SP_id].usedSigningKeys;
        }

        emit WithdrawalCredentialsSet(_withdrawalCredentials);
    }


    /**
      * @notice Add staking provider named `name` with reward address `rewardAddress` and staking limit `stakingLimit` validators
      * @param _name Human-readable name
      * @param _rewardAddress Ethereum 1 address which receives stETH rewards for this SP
      * @param _stakingLimit the maximum number of validators to stake for this SP
      * @return a unique key of the added SP
      */
    function addStakingProvider(string _name, address _rewardAddress, uint64 _stakingLimit) external
        auth(ADD_STAKING_PROVIDER_ROLE)
        validAddress(_rewardAddress)
        returns (uint256 id)
    {
        id = sps.length++;
        StakingProvider storage sp = sps[id];

        activeSPCount++;
        sp.active = true;
        sp.name = _name;
        sp.rewardAddress = _rewardAddress;
        sp.stakingLimit = _stakingLimit;

        emit StakingProviderAdded(id, _name, _rewardAddress, _stakingLimit);
    }

    /**
      * @notice `_active ? 'Enable' : 'Disable'` the staking provider #`_id`
      */
    function setStakingProviderActive(uint256 _id, bool _active) external
        authP(SET_STAKING_PROVIDER_ACTIVE_ROLE, arr(_id, _active ? uint256(1) : uint256(0)))
        SPExists(_id)
    {
        if (sps[_id].active != _active) {
            if (_active)
                activeSPCount++;
            else
                activeSPCount = activeSPCount.sub(1);
        }

        sps[_id].active = _active;

        emit StakingProviderActiveSet(_id, _active);
    }

    /**
      * @notice Change human-readable name of the staking provider #`_id` to `_name`
      */
    function setStakingProviderName(uint256 _id, string _name) external
        authP(SET_STAKING_PROVIDER_NAME_ROLE, arr(_id))
        SPExists(_id)
    {
        sps[_id].name = _name;
        emit StakingProviderNameSet(_id, _name);
    }

    /**
      * @notice Change reward address of the staking provider #`_id` to `_rewardAddress`
      */
    function setStakingProviderRewardAddress(uint256 _id, address _rewardAddress) external
        authP(SET_STAKING_PROVIDER_ADDRESS_ROLE, arr(_id, uint256(_rewardAddress)))
        SPExists(_id)
        validAddress(_rewardAddress)
    {
        sps[_id].rewardAddress = _rewardAddress;
        emit StakingProviderRewardAddressSet(_id, _rewardAddress);
    }

    /**
      * @notice Set the maximum number of validators to stake for the staking provider #`_id` to `_stakingLimit`
      */
    function setStakingProviderStakingLimit(uint256 _id, uint64 _stakingLimit) external
        authP(SET_STAKING_PROVIDER_LIMIT_ROLE, arr(_id, uint256(_stakingLimit)))
        SPExists(_id)
    {
        sps[_id].stakingLimit = _stakingLimit;
        emit StakingProviderStakingLimitSet(_id, _stakingLimit);
    }

    /**
      * @notice Report `_stoppedIncrement` more stopped validators of the staking provider #`_id`
      */
    function reportStoppedValidators(uint256 _id, uint64 _stoppedIncrement) external
        authP(REPORT_STOPPED_VALIDATORS_ROLE, arr(_id, uint256(_stoppedIncrement)))
        SPExists(_id)
    {
        require(0 != _stoppedIncrement, "EMPTY_VALUE");
        sps[_id].stoppedValidators = sps[_id].stoppedValidators.add(_stoppedIncrement);
        require(sps[_id].stoppedValidators <= sps[_id].usedSigningKeys, "STOPPED_MORE_THAN_LAUNCHED");

        emit StakingProviderTotalStoppedValidatorsReported(_id, sps[_id].stoppedValidators);
    }


    /**
      * @notice Add `_quantity` validator signing keys to the set of usable keys. Concatenated keys are: `_pubkeys`
      * @dev Along with each key the DAO has to provide a signatures for the
      *      (pubkey, withdrawal_credentials, 32000000000) message.
      *      Given that information, the contract'll be able to call
      *      validator_registration.deposit on-chain.
      * @param _SP_id Staking provider id
      * @param _quantity Number of signing keys provided
      * @param _pubkeys Several concatenated validator signing keys
      * @param _signatures Several concatenated signatures for (pubkey, withdrawal_credentials, 32000000000) messages
      */
    function addSigningKeys(uint256 _SP_id, uint256 _quantity, bytes _pubkeys, bytes _signatures) external
        SPExists(_SP_id)
    {
        require(msg.sender == sps[_SP_id].rewardAddress
                || canPerform(msg.sender, MANAGE_SIGNING_KEYS, arr(_SP_id)), "APP_AUTH_FAILED");

        require(_quantity != 0, "NO_KEYS");
        require(_pubkeys.length == _quantity.mul(PUBKEY_LENGTH), "INVALID_LENGTH");
        require(_signatures.length == _quantity.mul(SIGNATURE_LENGTH), "INVALID_LENGTH");

        for (uint256 i = 0; i < _quantity; ++i) {
            bytes memory key = BytesLib.slice(_pubkeys, i * PUBKEY_LENGTH, PUBKEY_LENGTH);
            require(!_isEmptySigningKey(key), "EMPTY_KEY");
            bytes memory sig = BytesLib.slice(_signatures, i * SIGNATURE_LENGTH, SIGNATURE_LENGTH);

            _storeSigningKey(_SP_id, sps[_SP_id].totalSigningKeys + i, key, sig);
            emit SigningKeyAdded(_SP_id, key);
        }

        sps[_SP_id].totalSigningKeys = sps[_SP_id].totalSigningKeys.add(to64(_quantity));
    }

    /**
      * @notice Removes a validator signing key #`_index` from the set of usable keys
      * @param _SP_id Staking provider id
      * @param _index Index of the key, starting with 0
      */
    function removeSigningKey(uint256 _SP_id, uint256 _index) external
        SPExists(_SP_id)
    {
        require(msg.sender == sps[_SP_id].rewardAddress
                || canPerform(msg.sender, MANAGE_SIGNING_KEYS, arr(_SP_id)), "APP_AUTH_FAILED");

        require(_index < sps[_SP_id].totalSigningKeys, "KEY_NOT_FOUND");
        require(_index >= sps[_SP_id].usedSigningKeys, "KEY_WAS_USED");

        (bytes memory removedKey, ) = _loadSigningKey(_SP_id, _index);

        uint256 lastIndex = sps[_SP_id].totalSigningKeys.sub(1);
        if (_index < lastIndex) {
            (bytes memory key, bytes memory signature) = _loadSigningKey(_SP_id, lastIndex);
            _storeSigningKey(_SP_id, _index, key, signature);
        }

        _deleteSigningKey(_SP_id, lastIndex);
        sps[_SP_id].totalSigningKeys = sps[_SP_id].totalSigningKeys.sub(1);

        emit SigningKeyRemoved(_SP_id, removedKey);
    }


    /**
      * @notice Issues withdrawal request. Large withdrawals will be processed only after the phase 2 launch. WIP.
      * @param _amount Amount of StETH to burn
      * @param _pubkeyHash Receiving address
      */
    function withdraw(uint256 _amount, bytes32 _pubkeyHash) external whenNotStopped {
        revert("NOT_IMPLEMENTED_YET");
    }


    /**
      * @notice Ether on the ETH 2.0 side reported by the oracle
      * @param _eth2balance Balance in wei on the ETH 2.0 side
      */
    function reportEther2(uint256 _epoch, uint256 _eth2balance) external {
        require(msg.sender == getOracle(), "APP_AUTH_FAILED");
        require(0 != _epoch, "ZERO_EPOCH");

        if (_epoch <= LAST_ORACLE_EPOCH_VALUE_POSITION.getStorageUint256())
            return; // ignore old data

        LAST_ORACLE_EPOCH_VALUE_POSITION.setStorageUint256(_epoch);
        REMOTE_ETHER2_VALUE_POSITION.setStorageUint256(_eth2balance);

        // Calculating real amount of rewards
        uint256 rewardBase = REWARD_BASE_VALUE_POSITION.getStorageUint256();
        if (_eth2balance > rewardBase) {
            uint256 rewards = _eth2balance.sub(rewardBase);
            REWARD_BASE_VALUE_POSITION.setStorageUint256(_eth2balance);
            distributeRewards(rewards);
        }
    }


    /**
     * @notice Send funds to recovery Vault. Overrides default AragonApp behaviour.
     * @param _token Token to be sent to recovery vault.
     */
    function transferToVault(address _token) external {
        require(allowRecoverability(_token), "RECOVER_DISALLOWED");
        address vault = getRecoveryVault();
        require(isContract(vault), "RECOVER_VAULT_NOT_CONTRACT");

        uint256 balance;
        if (_token == ETH) {
            balance = _getUnaccountedEther();
            vault.transfer(balance);
        } else {
            ERC20 token = ERC20(_token);
            balance = token.staticBalanceOf(this);
            require(token.safeTransfer(vault, balance), "RECOVER_TOKEN_TRANSFER_FAILED");
        }

        emit RecoverToVault(vault, _token, balance);
    }


    /**
      * @notice Returns staking rewards fee rate
      */
    function getFee() external view returns (uint16 feeBasisPoints) {
        return _getFee();
    }

    /**
      * @notice Returns fee distribution proportion
      */
    function getFeeDistribution() external view returns (uint16 treasuryFeeBasisPoints, uint16 insuranceFeeBasisPoints,
                                                         uint16 SPFeeBasisPoints)
    {
        return _getFeeDistribution();
    }

    /**
      * @notice Returns current credentials to withdraw ETH on ETH 2.0 side after the phase 2 is launched
      */
    function getWithdrawalCredentials() external view returns (bytes) {
        return withdrawalCredentials;
    }

    /**
      * @notice Returns total number of staking providers
      */
    function getStakingProvidersCount() external view returns (uint256) {
        return sps.length.sub(1);
    }

    /**
      * @notice Returns the n-th staking provider
      */
    function getStakingProvider(uint256 _id) external view
        SPExists(_id)
        returns
        (
            bool active,
            string name,
            address rewardAddress,
            uint64 stakingLimit,
            uint64 stoppedValidators,
            uint64 totalSigningKeys,
            uint64 usedSigningKeys
        )
    {
        StakingProvider storage sp = sps[_id];

        active = sp.active;
        name = sp.name;
        rewardAddress = sp.rewardAddress;
        stakingLimit = sp.stakingLimit;
        stoppedValidators = sp.stoppedValidators;
        totalSigningKeys = sp.totalSigningKeys;
        usedSigningKeys = sp.usedSigningKeys;
    }

    /**
      * @notice Returns total number of signing keys of the staking provider #`_SP_id`
      */
    function getTotalSigningKeyCount(uint256 _SP_id) external view SPExists(_SP_id) returns (uint256) {
        return sps[_SP_id].totalSigningKeys;
    }

    /**
      * @notice Returns number of usable signing keys of the staking provider #`_SP_id`
      */
    function getUnusedSigningKeyCount(uint256 _SP_id) external view SPExists(_SP_id) returns (uint256) {
        return sps[_SP_id].totalSigningKeys.sub(sps[_SP_id].usedSigningKeys);
    }

    /**
      * @notice Returns n-th signing key of the staking provider #`_SP_id`
      * @param _SP_id Staking provider id
      * @param _index Index of the key, starting with 0
      * @return key Key
      * @return used Flag indication if the key was used in the staking
      */
    function getSigningKey(uint256 _SP_id, uint256 _index) external view SPExists(_SP_id) returns (bytes key, bool used)
    {
        require(_index < sps[_SP_id].totalSigningKeys, "KEY_NOT_FOUND");

        (bytes memory key_, ) = _loadSigningKey(_SP_id, _index);

        return (key_, _index < sps[_SP_id].usedSigningKeys);
    }


    /**
      * @notice Gets the amount of Ether temporary buffered on this contract balance
      */
    function getBufferedEther() external view returns (uint256) {
        return _getBufferedEther();
    }

    /**
      * @notice Gets the amount of Ether controlled by the system
      */
    function getTotalControlledEther() external view returns (uint256) {
        return _getTotalControlledEther();
    }


    /**
      * @notice Gets liquid token interface handle
      */
    function getToken() public view returns (ISTETH) {
        return ISTETH(TOKEN_VALUE_POSITION.getStorageAddress());
    }

    /**
      * @notice Gets validator registration contract handle
      */
    function getValidatorRegistrationContract() public view returns (IValidatorRegistration) {
        return IValidatorRegistration(VALIDATOR_REGISTRATION_VALUE_POSITION.getStorageAddress());
    }

    /**
      * @notice Gets authorized oracle address
      */
    function getOracle() public view returns (address) {
        return ORACLE_VALUE_POSITION.getStorageAddress();
    }

    /**
      * @notice Returns the treasury address
      */
    function getTreasury() public view returns (address) {
        address vault = getRecoveryVault();
        require(isContract(vault), "RECOVER_VAULT_NOT_CONTRACT");
        return vault;
    }

    /**
      * @notice Returns the insurance fund address
      */
    function getInsuranceFund() public view returns (address) {
        // TODO a separate vault
        return getTreasury();
    }

    /**
      * @notice Gets the stat of the system's Ether on the Ethereum 2 side
      * @return deposited Amount of Ether deposited from the current Ethereum
      * @return remote Amount of Ether currently present on the Ethereum 2 side (can be 0 if the Ethereum 2 is yet to be launch
      */
    function getEther2Stat() external view returns (uint256 deposited, uint256 remote) {
        deposited = DEPOSITED_ETHER_VALUE_POSITION.getStorageUint256();
        remote = REMOTE_ETHER2_VALUE_POSITION.getStorageUint256();
    }


    /**
      * @dev Sets liquid token interface handle
      */
    function _setToken(ISTETH _token) internal {
        require(isContract(address(_token)), "NOT_A_CONTRACT");
        TOKEN_VALUE_POSITION.setStorageAddress(address(_token));
    }

    /**
      * @dev Sets validator registration contract handle
      */
    function _setValidatorRegistrationContract(IValidatorRegistration _contract) internal {
        require(isContract(address(_contract)), "NOT_A_CONTRACT");
        VALIDATOR_REGISTRATION_VALUE_POSITION.setStorageAddress(address(_contract));
    }

    /**
      * @dev Internal function to set authorized oracle address
      */
    function _setOracle(address _oracle) internal {
        require(isContract(_oracle), "NOT_A_CONTRACT");
        ORACLE_VALUE_POSITION.setStorageAddress(_oracle);
    }


    /**
      * @dev Processes user deposit
      */
    function _submit(address _referral) internal whenNotStopped returns (uint256 StETH) {
        address sender = msg.sender;
        uint256 deposit = msg.value;
        require(deposit != 0, "ZERO_DEPOSIT");

        // Minting new liquid tokens
        if (0 == _getTotalControlledEther()) {
            StETH = deposit;
        } else {
            assert(getToken().totalSupply() != 0);
            StETH = deposit.mul(getToken().totalSupply()).div(_getTotalControlledEther());
        }
        getToken().mint(sender, StETH);

        _submitted(sender, deposit, _referral);

        // Buffer management
        uint256 buffered = _getBufferedEther();
        if (buffered >= DEPOSIT_SIZE) {
            uint256 unaccounted = _getUnaccountedEther();

            uint256 toUnbuffer = buffered.div(DEPOSIT_SIZE).mul(DEPOSIT_SIZE);
            assert(toUnbuffer <= buffered && toUnbuffer != 0);

            _markAsUnbuffered(_ETH2Deposit(toUnbuffer));

            assert(_getUnaccountedEther() == unaccounted);
        }
    }

    /**
      * @dev Makes a deposit to the ETH 2.0 side
      * @param _amount Total amount to deposit to the ETH 2.0 side
      * @return actually deposited amount
      */
    function _ETH2Deposit(uint256 _amount) internal returns (uint256) {
        assert(_amount >= MIN_DEPOSIT_AMOUNT);
        if (0 == activeSPCount)
            return 0;

        // Memory is very cheap, although you don't want to grow it too much.
        DepositLookupCacheEntry[] memory cache = new DepositLookupCacheEntry[](activeSPCount);
        uint256 idx = 0;
        uint256 length = sps.length;
        for (uint256 SP_id = 1; SP_id < length; ++SP_id) {
            StakingProvider storage sp = sps[SP_id];
            if (!sp.active)
                continue;

            DepositLookupCacheEntry memory cached = cache[idx++];
            cached.id = SP_id;
            cached.stakingLimit = sp.stakingLimit;
            cached.stoppedValidators = sp.stoppedValidators;
            cached.totalSigningKeys = sp.totalSigningKeys;
            cached.usedSigningKeys = sp.usedSigningKeys;
            cached.initialUsedSigningKeys = cached.usedSigningKeys;
        }
        assert(idx == cache.length);

        uint256 deposited = 0;
        while (_amount != 0) {
            // Finding the best suitable SP
            uint256 bestSPidx = cache.length;   // 'not found' flag
            uint256 smallestStake;
            // The loop is ligthweight comparing to an ether transfer and .deposit invocation
            for (idx = 0; idx < cache.length; ++idx) {
                DepositLookupCacheEntry memory entry = cache[idx];

                assert(entry.usedSigningKeys <= entry.totalSigningKeys);
                if (entry.usedSigningKeys == entry.totalSigningKeys)
                    continue;

                uint256 stake = entry.usedSigningKeys.sub(entry.stoppedValidators);
                if (stake + 1 > entry.stakingLimit)
                    continue;

                if (bestSPidx == cache.length || stake < smallestStake) {
                    bestSPidx = idx;
                    smallestStake = stake;
                }
            }

            if (bestSPidx == cache.length)  // not found
                break;

            // Invoking deposit for the best SP
            _amount = _amount.sub(DEPOSIT_SIZE);
            deposited = deposited.add(DEPOSIT_SIZE);

            (bytes memory key, bytes memory signature) =
                    _loadSigningKey(cache[bestSPidx].id, cache[bestSPidx].usedSigningKeys++);

            // finally, stake the notch for the assigned validator
            _stake(key, signature);
        }

        if (0 != deposited) {
            REWARD_BASE_VALUE_POSITION.setStorageUint256(REWARD_BASE_VALUE_POSITION.getStorageUint256().add(deposited));

            // Write back usedSigningKeys
            for (idx = 0; idx < cache.length; ++idx) {
                entry = cache[idx];
                if (entry.usedSigningKeys > entry.initialUsedSigningKeys)
                    sps[cache[idx].id].usedSigningKeys = to64(entry.usedSigningKeys);
            }
        }

        return deposited;
    }

    /**
      * @dev Invokes a validator_registration.deposit call
      * @param _pubkey Validator to stake for
      * @param _signature Signature of the deposit call
      */
    function _stake(bytes memory _pubkey, bytes memory _signature) internal {
        require(withdrawalCredentials.length != 0, "EMPTY_WITHDRAWAL_CREDENTIALS");

        uint256 value = DEPOSIT_SIZE;

        // The following computations and Merkle tree-ization will make validator_registration.vy happy
        uint256 depositAmount = value.div(DEPOSIT_AMOUNT_UNIT);
        assert(depositAmount.mul(DEPOSIT_AMOUNT_UNIT) == value);    // properly rounded

        // Compute deposit data root (`DepositData` hash tree root) according to validator_registration.vy
        bytes32 pubkeyRoot = keccak256(_pad64(_pubkey));
        bytes32 signatureRoot = keccak256(abi.encodePacked(
            keccak256(BytesLib.slice(_signature, 0, 64)),
            keccak256(_pad64(BytesLib.slice(_signature, 64, SIGNATURE_LENGTH.sub(64))))
        ));

        bytes32 depositDataRoot = keccak256(abi.encodePacked(
            keccak256(abi.encodePacked(pubkeyRoot, withdrawalCredentials)),
            keccak256(abi.encodePacked(_toLittleEndian64(depositAmount), signatureRoot))
        ));

        uint256 targetBalance = address(this).balance.sub(value);

        getValidatorRegistrationContract().deposit.value(value)(
            _pubkey, withdrawalCredentials, _signature, depositDataRoot);
        require(address(this).balance == targetBalance, "EXPECTING_DEPOSIT_TO_HAPPEN");
    }

    /**
      * @dev Distributes rewards and fees.
      * @param _rewards Total rewards accrued on the Ethereum 2.0 side.
      */
    function distributeRewards(uint256 _rewards) internal {
        // Amount of the rewards in Ether
        uint256 protocolRewards = _rewards.mul(_getFee()).div(10000);

        assert(0 != getToken().totalSupply());
        // Amount of StETH we should mint to distribute protocolRewards by diluting the totalSupply
        uint256 tokens2mint = protocolRewards.mul(getToken().totalSupply()).div(
            _getTotalControlledEther().sub(protocolRewards));

        (uint16 treasuryFeeBasisPoints, uint16 insuranceFeeBasisPoints, uint16 SPFeeBasisPoints) = _getFeeDistribution();
        uint256 toTreasury = tokens2mint.mul(treasuryFeeBasisPoints).div(10000);
        uint256 toInsuranceFund = tokens2mint.mul(insuranceFeeBasisPoints).div(10000);
        uint256 toSP = tokens2mint.sub(toTreasury).sub(toInsuranceFund);

        getToken().mint(getTreasury(), toTreasury);
        getToken().mint(getInsuranceFund(), toInsuranceFund);
        getToken().mint(address(this), toSP);

        distributeRewardsToSP(toSP);
    }

    /**
      * @dev Distributes rewards to the staking providers.
      * @param _SPTokens Rewards in the form of StETH tokens.
      */
    function distributeRewardsToSP(uint256 _SPTokens) internal {
        // TODO staking providers
    }


    /**
      * @dev Records a deposit made by a user with optional referral
      * @param _value Deposit value in wei
      */
    function _submitted(address _sender, uint256 _value, address _referral) internal {
        BUFFERED_ETHER_VALUE_POSITION.setStorageUint256(_getBufferedEther().add(_value));

        emit Submitted(_sender, _value, _referral);
    }

    /**
      * @dev Records a deposit to the validator_registration.deposit function.
      * @param _amount Total amount deposited to the ETH 2.0 side
      */
    function _markAsUnbuffered(uint256 _amount) internal {
        DEPOSITED_ETHER_VALUE_POSITION.setStorageUint256(
            DEPOSITED_ETHER_VALUE_POSITION.getStorageUint256().add(_amount));
        BUFFERED_ETHER_VALUE_POSITION.setStorageUint256(
            BUFFERED_ETHER_VALUE_POSITION.getStorageUint256().sub(_amount));

        emit Unbuffered(_amount);
    }

    /**
      * @dev Write a value nominated in basis points
      */
    function _setBPValue(bytes32 _slot, uint16 _value) internal {
        require(_value <= 10000, "VALUE_OVER_100_PERCENT");
        _slot.setStorageUint256(uint256(_value));
    }


    /**
      * @dev Returns staking rewards fee rate
      */
    function _getFee() internal view returns (uint16) {
        return _readBPValue(FEE_VALUE_POSITION);
    }

    /**
      * @dev Returns fee distribution proportion
      */
    function _getFeeDistribution() internal view
        returns (uint16 treasuryFeeBasisPoints, uint16 insuranceFeeBasisPoints, uint16 SPFeeBasisPoints)
    {
        treasuryFeeBasisPoints = _readBPValue(TREASURY_FEE_VALUE_POSITION);
        insuranceFeeBasisPoints = _readBPValue(INSURANCE_FEE_VALUE_POSITION);
        SPFeeBasisPoints = _readBPValue(SP_FEE_VALUE_POSITION);
    }

    /**
      * @dev Read a value nominated in basis points
      */
    function _readBPValue(bytes32 _slot) internal view returns (uint16) {
        uint256 v = _slot.getStorageUint256();
        assert(v <= 10000);
        return uint16(v);
    }

    /**
      * @dev Gets the amount of Ether temporary buffered on this contract balance
      */
    function _getBufferedEther() internal view returns (uint256) {
        uint256 buffered = BUFFERED_ETHER_VALUE_POSITION.getStorageUint256();
        assert(address(this).balance >= buffered);

        return buffered;
    }

    /**
      * @dev Gets unaccounted (excess) Ether on this contract balance
      */
    function _getUnaccountedEther() internal view returns (uint256) {
        return address(this).balance.sub(_getBufferedEther());
    }

    /**
      * @dev Returns true if the oracle ever provided data
      */
    function _hasOracleData() internal view returns (bool) {
        return 0 != LAST_ORACLE_EPOCH_VALUE_POSITION.getStorageUint256();
    }

    /**
      * @dev Gets the amount of Ether controlled by the system
      */
    function _getTotalControlledEther() internal view returns (uint256) {
        uint256 remote = REMOTE_ETHER2_VALUE_POSITION.getStorageUint256();
        // Until the oracle provides data, we assume that all staked ether is intact.
        uint256 deposited = DEPOSITED_ETHER_VALUE_POSITION.getStorageUint256();

        uint256 assets = _getBufferedEther().add(_hasOracleData() ? remote : deposited);

        return assets;
    }


    /**
      * @dev Fast dynamic array comparison
      */
    function _isEqual(bytes memory _a, bytes memory _b) internal pure returns (bool) {
        uint256 length = _a.length;
        if (length != _b.length)
            return false;

        if (length > 0 && _a[length - 1] != _b[length - 1])
            return false;
        if (length > 1 && _a[length - 2] != _b[length - 2])
            return false;

        return keccak256(_a) == keccak256(_b);
    }

    /**
      * @dev Padding memory array with zeroes up to 64 bytes on the right
      * @param _b Memory array of size 32 .. 64
      */
    function _pad64(bytes memory _b) internal pure returns (bytes memory) {
        assert(_b.length >= 32 && _b.length <= 64);
        if (64 == _b.length)
            return _b;

        bytes memory zero32 = new bytes(32);
        assembly { mstore(add(zero32, 0x20), 0) }

        if (32 == _b.length)
            return BytesLib.concat(_b, zero32);
        else
            return BytesLib.concat(_b, BytesLib.slice(zero32, 0, uint256(64).sub(_b.length)));
    }

    /**
      * @dev Converting value to little endian bytes and padding up to 32 bytes on the right
      * @param _value Number less than `2**64` for compatibility reasons
      */
    function _toLittleEndian64(uint256 _value) internal pure returns (uint256 result) {
        result = 0;
        for (uint256 i = 0; i < 8; ++i) {
            result = (result << 8) | (_value & 0xFF);
            _value >>= 8;
        }

        assert(0 == _value);    // fully converted
        result <<= (24 * 8);
    }

    function _isEmptySigningKey(bytes memory _key) internal pure returns (bool) {
        assert(_key.length == PUBKEY_LENGTH);
        // algorithm applicability constraint
        assert(PUBKEY_LENGTH >= 32 && PUBKEY_LENGTH <= 64);

        uint256 k1;
        uint256 k2;
        assembly {
            k1 := mload(add(_key, 0x20))
            k2 := mload(add(_key, 0x40))
        }

        return 0 == k1 && 0 == (k2 >> ((2 * 32 - PUBKEY_LENGTH) * 8));
    }

    function to64(uint256 v) internal pure returns (uint64) {
        assert(v <= uint256(uint64(-1)));
        return uint64(v);
    }

    function _signingKeyOffset(uint256 _SP_id, uint256 _keyIndex) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(SIGNING_KEYS_MAPPING_NAME, _SP_id, _keyIndex)));
    }

    function _storeSigningKey(uint256 _SP_id, uint256 _keyIndex, bytes memory _key, bytes memory _signature) internal {
        assert(_key.length == PUBKEY_LENGTH);
        assert(_signature.length == SIGNATURE_LENGTH);
        // algorithm applicability constraints
        assert(PUBKEY_LENGTH >= 32 && PUBKEY_LENGTH <= 64);
        assert(0 == SIGNATURE_LENGTH % 32);

        // key
        uint256 offset = _signingKeyOffset(_SP_id, _keyIndex);
        uint256 keyExcessBits = (2 * 32 - PUBKEY_LENGTH) * 8;
        assembly {
            sstore(offset, mload(add(_key, 0x20)))
            sstore(add(offset, 1), shl(keyExcessBits, shr(keyExcessBits, mload(add(_key, 0x40)))))
        }
        offset += 2;

        // signature
        for (uint256 i = 0; i < SIGNATURE_LENGTH; i += 32) {
            assembly {
                sstore(offset, mload(add(_signature, add(0x20, i))))
            }
            offset++;
        }
    }

    function _deleteSigningKey(uint256 _SP_id, uint256 _keyIndex) internal {
        uint256 offset = _signingKeyOffset(_SP_id, _keyIndex);
        for (uint256 i = 0; i < (PUBKEY_LENGTH + SIGNATURE_LENGTH) / 32 + 1; ++i) {
            assembly {
                sstore(add(offset, i), 0)
            }
        }
    }

    function _loadSigningKey(uint256 _SP_id, uint256 _keyIndex) internal view returns (bytes memory key, bytes memory signature) {
        // algorithm applicability constraints
        assert(PUBKEY_LENGTH >= 32 && PUBKEY_LENGTH <= 64);
        assert(0 == SIGNATURE_LENGTH % 32);

        uint256 offset = _signingKeyOffset(_SP_id, _keyIndex);

        // key
        bytes memory tmpKey = new bytes(64);
        assembly {
            mstore(add(tmpKey, 0x20), sload(offset))
            mstore(add(tmpKey, 0x40), sload(add(offset, 1)))
        }
        offset += 2;
        key = BytesLib.slice(tmpKey, 0, PUBKEY_LENGTH);

        // signature
        signature = new bytes(SIGNATURE_LENGTH);
        for (uint256 i = 0; i < SIGNATURE_LENGTH; i += 32) {
            assembly {
                mstore(add(signature, add(0x20, i)), sload(offset))
            }
            offset++;
        }
    }
}
