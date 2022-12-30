const { newDao, newApp } = require('../../0.4.24/helpers/dao')

const Lido = artifacts.require('LidoMock.sol')
const NodeOperatorsRegistry = artifacts.require('NodeOperatorsRegistry')
const OracleMock = artifacts.require('OracleMock.sol')
const DepositContractMock = artifacts.require('DepositContractMock.sol')
const DepositSecurityModule = artifacts.require('DepositSecurityModule.sol')
const StakingRouter = artifacts.require('StakingRouterMock.sol')

module.exports = {
  deployDaoAndPool
}

const NETWORK_ID = 1000
const MAX_DEPOSITS_PER_BLOCK = 100
const MIN_DEPOSIT_BLOCK_DISTANCE = 20
const PAUSE_INTENT_VALIDITY_PERIOD_BLOCKS = 10
const GUARDIAN1 = '0x5Fc0E75BF6502009943590492B02A1d08EAc9C43'
const GUARDIAN2 = '0x8516Cbb5ABe73D775bfc0d21Af226e229F7181A3'
const GUARDIAN3 = '0xdaEAd0E0194abd565d28c1013399801d79627c14'
const GUARDIAN_PRIVATE_KEYS = {
  [GUARDIAN1]: '0x3578665169e03e05a26bd5c565ffd12c81a1e0df7d0679f8aee4153110a83c8c',
  [GUARDIAN2]: '0x88868f0fb667cfe50261bb385be8987e0ce62faee934af33c3026cf65f25f09e',
  [GUARDIAN3]: '0x75e6f508b637327debc90962cd38943ddb9cfc1fc4a8572fc5e3d0984e1261de'
}
const DEPOSIT_ROOT = '0xd151867719c94ad8458feaf491809f9bc8096c702a72747403ecaac30c179137'
const CURATED_TYPE = web3.utils.fromAscii('curated')

async function deployDaoAndPool(appManager, voting) {
  // Deploy the DAO, oracle and deposit contract mocks, and base contracts for
  // Lido (the pool) and NodeOperatorsRegistry (the Node Operators registry)

  const treasury = web3.eth.accounts.create()

  const [{ dao, acl }, oracleMock, depositContractMock, poolBase, nodeOperatorRegistryBase] = await Promise.all([
    newDao(appManager),
    OracleMock.new(),
    DepositContractMock.new(),
    Lido.new(),
    NodeOperatorsRegistry.new()
  ])

  const stakingRouter = await StakingRouter.new(depositContractMock.address)

  // Instantiate proxies for the pool, the token, and the node operators registry, using
  // the base contracts as their logic implementation

  const [poolProxyAddress, nodeOperatorRegistryProxyAddress] = await Promise.all([
    newApp(dao, 'lido', poolBase.address, appManager),
    newApp(dao, 'node-operators-registry', nodeOperatorRegistryBase.address, appManager)
  ])

  const [token, pool, nodeOperatorRegistry] = await Promise.all([
    Lido.at(poolProxyAddress),
    Lido.at(poolProxyAddress),
    NodeOperatorsRegistry.at(nodeOperatorRegistryProxyAddress)
  ])

  const depositSecurityModule = await DepositSecurityModule.new(
    pool.address,
    depositContractMock.address,
    stakingRouter.address,
    MAX_DEPOSITS_PER_BLOCK,
    MIN_DEPOSIT_BLOCK_DISTANCE,
    PAUSE_INTENT_VALIDITY_PERIOD_BLOCKS,
    { from: appManager }
  )
  await depositSecurityModule.addGuardians([GUARDIAN3, GUARDIAN1, GUARDIAN2], 2, { from: appManager })

  // Initialize the node operators registry and the pool
  await nodeOperatorRegistry.initialize(token.address, '0x01')

  const [
    POOL_PAUSE_ROLE,
    POOL_RESUME_ROLE,
    POOL_BURN_ROLE,
    STAKING_PAUSE_ROLE,
    STAKING_CONTROL_ROLE,
    SET_EL_REWARDS_VAULT_ROLE,
    SET_EL_REWARDS_WITHDRAWAL_LIMIT_ROLE,
    MANAGE_PROTOCOL_CONTRACTS_ROLE,
    NODE_OPERATOR_REGISTRY_MANAGE_SIGNING_KEYS,
    NODE_OPERATOR_REGISTRY_ADD_NODE_OPERATOR_ROLE,
    NODE_OPERATOR_REGISTRY_ACTIVATE_NODE_OPERATOR_ROLE,
    NODE_OPERATOR_REGISTRY_DEACTIVATE_NODE_OPERATOR_ROLE,
    NODE_OPERATOR_REGISTRY_SET_NODE_OPERATOR_NAME_ROLE,
    NODE_OPERATOR_REGISTRY_SET_NODE_OPERATOR_ADDRESS_ROLE,
    NODE_OPERATOR_REGISTRY_SET_NODE_OPERATOR_LIMIT_ROLE,
    NODE_OPERATOR_REGISTRY_UPDATE_EXITED_VALIDATORS_KEYS_COUNT_ROLE,
    NODE_OPERATOR_REGISTRY_REQUEST_VALIDATORS_KEYS_FOR_DEPOSITS_ROLE,
    NODE_OPERATOR_REGISTRY_INVALIDATE_READY_TO_DEPOSIT_KEYS
  ] = await Promise.all([
    pool.PAUSE_ROLE(),
    pool.RESUME_ROLE(),
    pool.BURN_ROLE(),
    pool.STAKING_PAUSE_ROLE(),
    pool.STAKING_CONTROL_ROLE(),
    pool.SET_EL_REWARDS_VAULT_ROLE(),
    pool.SET_EL_REWARDS_WITHDRAWAL_LIMIT_ROLE(),
    pool.MANAGE_PROTOCOL_CONTRACTS_ROLE(),
    nodeOperatorRegistry.MANAGE_SIGNING_KEYS(),
    nodeOperatorRegistry.ADD_NODE_OPERATOR_ROLE(),
    nodeOperatorRegistry.ACTIVATE_NODE_OPERATOR_ROLE(),
    nodeOperatorRegistry.DEACTIVATE_NODE_OPERATOR_ROLE(),
    nodeOperatorRegistry.SET_NODE_OPERATOR_NAME_ROLE(),
    nodeOperatorRegistry.SET_NODE_OPERATOR_ADDRESS_ROLE(),
    nodeOperatorRegistry.SET_NODE_OPERATOR_LIMIT_ROLE(),
    nodeOperatorRegistry.UPDATE_EXITED_VALIDATORS_KEYS_COUNT_ROLE(),
    nodeOperatorRegistry.REQUEST_VALIDATORS_KEYS_FOR_DEPOSITS_ROLE(),
    nodeOperatorRegistry.INVALIDATE_READY_TO_DEPOSIT_KEYS()
  ])

  await Promise.all([
    // Allow voting to manage the pool
    acl.createPermission(voting, pool.address, POOL_PAUSE_ROLE, appManager, { from: appManager }),
    acl.createPermission(voting, pool.address, POOL_RESUME_ROLE, appManager, { from: appManager }),
    acl.createPermission(voting, pool.address, POOL_BURN_ROLE, appManager, { from: appManager }),
    acl.createPermission(voting, pool.address, STAKING_PAUSE_ROLE, appManager, { from: appManager }),
    acl.createPermission(voting, pool.address, STAKING_CONTROL_ROLE, appManager, { from: appManager }),
    acl.createPermission(voting, pool.address, SET_EL_REWARDS_VAULT_ROLE, appManager, { from: appManager }),
    acl.createPermission(voting, pool.address, SET_EL_REWARDS_WITHDRAWAL_LIMIT_ROLE, appManager, { from: appManager }),
    acl.createPermission(voting, pool.address, MANAGE_PROTOCOL_CONTRACTS_ROLE, appManager, { from: appManager }),

    // Allow voting to manage node operators registry
    acl.createPermission(voting, nodeOperatorRegistry.address, NODE_OPERATOR_REGISTRY_MANAGE_SIGNING_KEYS, appManager, {
      from: appManager
    }),
    acl.createPermission(voting, nodeOperatorRegistry.address, NODE_OPERATOR_REGISTRY_ADD_NODE_OPERATOR_ROLE, appManager, {
      from: appManager
    }),
    acl.createPermission(voting, nodeOperatorRegistry.address, NODE_OPERATOR_REGISTRY_ACTIVATE_NODE_OPERATOR_ROLE, appManager, {
      from: appManager
    }),
    acl.createPermission(voting, nodeOperatorRegistry.address, NODE_OPERATOR_REGISTRY_DEACTIVATE_NODE_OPERATOR_ROLE, appManager, {
      from: appManager
    }),
    acl.createPermission(voting, nodeOperatorRegistry.address, NODE_OPERATOR_REGISTRY_SET_NODE_OPERATOR_NAME_ROLE, appManager, {
      from: appManager
    }),
    acl.createPermission(voting, nodeOperatorRegistry.address, NODE_OPERATOR_REGISTRY_SET_NODE_OPERATOR_ADDRESS_ROLE, appManager, {
      from: appManager
    }),
    acl.createPermission(voting, nodeOperatorRegistry.address, NODE_OPERATOR_REGISTRY_SET_NODE_OPERATOR_LIMIT_ROLE, appManager, {
      from: appManager
    }),
    acl.createPermission(
      voting,
      nodeOperatorRegistry.address,
      NODE_OPERATOR_REGISTRY_UPDATE_EXITED_VALIDATORS_KEYS_COUNT_ROLE,
      appManager,
      { from: appManager }
    ),
    acl.createPermission(
      stakingRouter.address,
      nodeOperatorRegistry.address,
      NODE_OPERATOR_REGISTRY_REQUEST_VALIDATORS_KEYS_FOR_DEPOSITS_ROLE,
      appManager,
      {
        from: appManager
      }
    ),
    acl.createPermission(
      stakingRouter.address,
      nodeOperatorRegistry.address,
      NODE_OPERATOR_REGISTRY_INVALIDATE_READY_TO_DEPOSIT_KEYS,
      appManager,
      {
        from: appManager
      }
    )
  ])

  const wc = '0x'.padEnd(66, '1234')
  await stakingRouter.initialize(appManager, pool.address, wc, { from: appManager })

  // Set up the staking router permissions.
  const [MANAGE_WITHDRAWAL_CREDENTIALS_ROLE, MODULE_PAUSE_ROLE, MODULE_MANAGE_ROLE, STAKING_ROUTER_DEPOSIT_ROLE] = await Promise.all([
    stakingRouter.MANAGE_WITHDRAWAL_CREDENTIALS_ROLE(),
    stakingRouter.MODULE_PAUSE_ROLE(),
    stakingRouter.MODULE_MANAGE_ROLE(),
    stakingRouter.STAKING_ROUTER_DEPOSIT_ROLE()
  ])

  await stakingRouter.grantRole(MANAGE_WITHDRAWAL_CREDENTIALS_ROLE, voting, { from: appManager })
  await stakingRouter.grantRole(MODULE_PAUSE_ROLE, voting, { from: appManager })
  await stakingRouter.grantRole(MODULE_MANAGE_ROLE, voting, { from: appManager })
  await stakingRouter.grantRole(STAKING_ROUTER_DEPOSIT_ROLE, pool.address, { from: appManager })

  await stakingRouter.addModule(
    'Curated',
    nodeOperatorRegistry.address,
    10_000, // 100 % _targetShare
    500, // 5 % _moduleFee
    500, // 5 % _treasuryFee
    { from: voting }
  )

  await pool.initialize(oracleMock.address, treasury.address, stakingRouter.address, depositSecurityModule.address)

  await oracleMock.setPool(pool.address)
  await depositContractMock.reset()
  await depositContractMock.set_deposit_root(DEPOSIT_ROOT)

  const treasuryAddr = await pool.getTreasury()

  return {
    dao,
    acl,
    oracleMock,
    depositContractMock,
    token,
    pool,
    nodeOperatorRegistry,
    treasuryAddr,
    depositSecurityModule,
    guardians: {
      privateKeys: GUARDIAN_PRIVATE_KEYS,
      addresses: [GUARDIAN1, GUARDIAN2, GUARDIAN3]
    },
    stakingRouter
  }
}
