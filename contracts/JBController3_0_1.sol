// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import '@openzeppelin/contracts/utils/introspection/ERC165.sol';
import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@paulrberg/contracts/math/PRBMath.sol';
import './abstract/JBOperatable.sol';
import './interfaces/IJBController3_0_1.sol';
import './interfaces/IJBController.sol';
import './interfaces/IJBMigratable.sol';
import './interfaces/IJBOperatorStore.sol';
import './interfaces/IJBPaymentTerminal.sol';
import './interfaces/IJBProjects.sol';
import './libraries/JBConstants.sol';
import './libraries/JBFundingCycleMetadataResolver.sol';
import './libraries/JBOperations.sol';
import './libraries/JBSplitsGroups.sol';

/**
  @notice
  Stitches together funding cycles and project tokens, making sure all activity is accounted for and correct.

  @dev
  Adheres to -
  IJBController3_1: General interface for the generic controller methods in this contract that interacts with funding cycles and tokens according to the protocol's rules.
  IJBMigratable: Allows migrating to this contract, with a hook called to prepare for the migration.

  @dev
  Inherits from -
  JBOperatable: Several functions in this contract can only be accessed by a project owner, or an address that has been preconfifigured to be an operator of the project.
  ERC165: Introspection on interface adherance. 

  @dev
  This Controller manages a project's reserved tokens explicitly instead of through a passive tracker property. 
  It is backwards compatible with the original IJBController, and exposes convenience view methods as part of IJBController3_1 for clearer queries.
*/
contract JBController3_0_1 is JBOperatable, ERC165, IJBController, IJBController3_0_1, IJBMigratable {
  // A library that parses the packed funding cycle metadata into a more friendly format.
  using JBFundingCycleMetadataResolver for JBFundingCycle;

  //*********************************************************************//
  // --------------------------- custom errors ------------------------- //
  //*********************************************************************//
  error BURN_PAUSED_AND_SENDER_NOT_VALID_TERMINAL_DELEGATE();
  error CANT_MIGRATE_TO_CURRENT_CONTROLLER();
  error FUNDING_CYCLE_ALREADY_LAUNCHED();
  error INVALID_BALLOT_REDEMPTION_RATE();
  error INVALID_DISTRIBUTION_LIMIT();
  error INVALID_DISTRIBUTION_LIMIT_CURRENCY();
  error INVALID_OVERFLOW_ALLOWANCE();
  error INVALID_OVERFLOW_ALLOWANCE_CURRENCY();
  error INVALID_REDEMPTION_RATE();
  error INVALID_RESERVED_RATE();
  error MIGRATION_NOT_ALLOWED();
  error MINT_NOT_ALLOWED_AND_NOT_TERMINAL_DELEGATE();
  error NO_BURNABLE_TOKENS();
  error NOT_CURRENT_CONTROLLER();
  error OVERFLOW_ALERT();
  error ZERO_TOKENS_TO_MINT();

  //*********************************************************************//
  // --------------------- internal stored properties ------------------ //
  //*********************************************************************//

  /**
    @notice
    Data regarding the distribution limit of a project during a configuration.

    @dev
    bits 0-231: The amount of token that a project can distribute per funding cycle.

    @dev
    bits 232-255: The currency of amount that a project can distribute.

    _projectId The ID of the project to get the packed distribution limit data of.
    _configuration The configuration during which the packed distribution limit data applies.
    _terminal The terminal from which distributions are being limited.
    _token The token for which distributions are being limited.
  */
  mapping(uint256 => mapping(uint256 => mapping(IJBPaymentTerminal => mapping(address => uint256))))
    internal _packedDistributionLimitDataOf;

  /**
    @notice
    Data regarding the overflow allowance of a project during a configuration.

    @dev
    bits 0-231: The amount of overflow that a project is allowed to tap into on-demand throughout the configuration.

    @dev
    bits 232-255: The currency of the amount of overflow that a project is allowed to tap.

    _projectId The ID of the project to get the packed overflow allowance data of.
    _configuration The configuration during which the packed overflow allowance data applies.
    _terminal The terminal managing the overflow.
    _token The token for which overflow is being allowed.
  */
  mapping(uint256 => mapping(uint256 => mapping(IJBPaymentTerminal => mapping(address => uint256))))
    internal _packedOverflowAllowanceDataOf;

  /**
    @notice
    The current undistributed reserved token balance of.

    _projectId The ID of the project to get a reserved token balance of.
  */
  mapping(uint256 => uint256) internal _reservedTokenBalanceOf;

  //*********************************************************************//
  // --------------- public immutable stored properties ---------------- //
  //*********************************************************************//

  /**
    @notice
    Mints ERC-721's that represent project ownership.
  */
  IJBProjects public immutable override projects;

  /**
    @notice
    The contract storing all funding cycle configurations.
  */
  IJBFundingCycleStore public immutable override fundingCycleStore;

  /**
    @notice
    The contract that manages token minting and burning.
  */
  IJBTokenStore public immutable override tokenStore;

  /**
    @notice
    The contract that stores splits for each project.
  */
  IJBSplitsStore public immutable override splitsStore;

  /**
    @notice
    The directory of terminals and controllers for projects.
  */
  IJBDirectory public immutable override directory;

  //*********************************************************************//
  // ------------------------- external views -------------------------- //
  //*********************************************************************//

  /**
    @notice
    The amount of token that a project can distribute per funding cycle, and the currency it's in terms of.

    @dev
    The number of decimals in the returned fixed point amount is the same as that of the specified terminal. 

    @param _projectId The ID of the project to get the distribution limit of.
    @param _configuration The configuration during which the distribution limit applies.
    @param _terminal The terminal from which distributions are being limited.
    @param _token The token for which the distribution limit applies.

    @return The distribution limit, as a fixed point number with the same number of decimals as the provided terminal.
    @return The currency of the distribution limit.
  */
  function distributionLimitOf(
    uint256 _projectId,
    uint256 _configuration,
    IJBPaymentTerminal _terminal,
    address _token
  ) external view override returns (uint256, uint256) {
    // Get a reference to the packed data.
    uint256 _data = _packedDistributionLimitDataOf[_projectId][_configuration][_terminal][_token];

    // The limit is in bits 0-231. The currency is in bits 232-255.
    return (uint256(uint232(_data)), _data >> 232);
  }

  /**
    @notice
    The amount of overflow that a project is allowed to tap into on-demand throughout a configuration, and the currency it's in terms of.

    @dev
    The number of decimals in the returned fixed point amount is the same as that of the specified terminal. 

    @param _projectId The ID of the project to get the overflow allowance of.
    @param _configuration The configuration of the during which the allowance applies.
    @param _terminal The terminal managing the overflow.
    @param _token The token for which the overflow allowance applies.

    @return The overflow allowance, as a fixed point number with the same number of decimals as the provided terminal.
    @return The currency of the overflow allowance.
  */
  function overflowAllowanceOf(
    uint256 _projectId,
    uint256 _configuration,
    IJBPaymentTerminal _terminal,
    address _token
  ) external view override returns (uint256, uint256) {
    // Get a reference to the packed data.
    uint256 _data = _packedOverflowAllowanceDataOf[_projectId][_configuration][_terminal][_token];

    // The allowance is in bits 0-231. The currency is in bits 232-255.
    return (uint256(uint232(_data)), _data >> 232);
  }

  /** 
    @notice
    A project's funding cycle for the specified configuration along with its metadata.

    @param _projectId The ID of the project to which the funding cycle belongs.
  
    @return fundingCycle The funding cycle.
    @return metadata The funding cycle's metadata.
  */
  function getFundingCycleOf(uint256 _projectId, uint256 _configuration)
    external
    view
    override
    returns (JBFundingCycle memory fundingCycle, JBFundingCycleMetadata memory metadata)
  {
    fundingCycle = fundingCycleStore.get(_projectId, _configuration);
    metadata = fundingCycle.expandMetadata();
  }

  /** 
    @notice
    A project's latest configured funding cycle along with its metadata and the ballot state of the configuration.

    @param _projectId The ID of the project to which the funding cycle belongs.
  
    @return fundingCycle The latest configured funding cycle.
    @return metadata The latest configured funding cycle's metadata.
    @return ballotState The state of the configuration.
  */
  function latestConfiguredFundingCycleOf(uint256 _projectId)
    external
    view
    override
    returns (
      JBFundingCycle memory fundingCycle,
      JBFundingCycleMetadata memory metadata,
      JBBallotState ballotState
    )
  {
    (fundingCycle, ballotState) = fundingCycleStore.latestConfiguredOf(_projectId);
    metadata = fundingCycle.expandMetadata();
  }

  /** 
    @notice
    A project's current funding cycle along with its metadata.

    @param _projectId The ID of the project to which the funding cycle belongs.
  
    @return fundingCycle The current funding cycle.
    @return metadata The current funding cycle's metadata.
  */
  function currentFundingCycleOf(uint256 _projectId)
    external
    view
    override
    returns (JBFundingCycle memory fundingCycle, JBFundingCycleMetadata memory metadata)
  {
    fundingCycle = fundingCycleStore.currentOf(_projectId);
    metadata = fundingCycle.expandMetadata();
  }

  /** 
    @notice
    A project's queued funding cycle along with its metadata.

    @param _projectId The ID of the project to which the funding cycle belongs.
  
    @return fundingCycle The queued funding cycle.
    @return metadata The queued funding cycle's metadata.
  */
  function queuedFundingCycleOf(uint256 _projectId)
    external
    view
    override
    returns (JBFundingCycle memory fundingCycle, JBFundingCycleMetadata memory metadata)
  {
    fundingCycle = fundingCycleStore.queuedOf(_projectId);
    metadata = fundingCycle.expandMetadata();
  }

  /**	
    @notice	
    Gets the amount of reserved tokens that a project has available to distribute.	

    @param _projectId The ID of the project to get a reserved token balance of.	

    @return The current amount of reserved tokens.	
  */
  function reservedTokenBalanceOf(uint256 _projectId) external view override returns (uint256) {
    return _reservedTokenBalanceOf[_projectId];
  }

  /**	
    @notice	
    Gets the amount of reserved tokens that a project has available to distribute.	

    @dev
    This is just for IJBController backwards compatibility.

    @param _projectId The ID of the project to get a reserved token balance of.	
    @param _reservedRate The reserved rate to use when making the calculation.	

    @return The current amount of reserved tokens.	
  */
  function reservedTokenBalanceOf(uint256 _projectId, uint256 _reservedRate)
    external
    view
    override
    returns (uint256)
  {
    _reservedRate;
    return _reservedTokenBalanceOf[_projectId];
  }

  /**	
    @notice	
    Gets the current total amount of outstanding tokens for a project, given a reserved rate.	

    @dev
    This is just for IJBController backwards compatibility.

    @param _projectId The ID of the project to get total outstanding tokens of.	
    @param _reservedRate The reserved rate to use when making the calculation.	

    @return The current total amount of outstanding tokens for the project.	
  */
  function totalOutstandingTokensOf(uint256 _projectId, uint256 _reservedRate)
    external
    view
    override
    returns (uint256)
  {
    _reservedRate;
    // Add the reserved tokens to the total supply.
    return totalOutstandingTokensOf(_projectId);
  }

  //*********************************************************************//
  // -------------------------- public views --------------------------- //
  //*********************************************************************//

  /**
    @notice
    Gets the current total amount of outstanding tokens for a project.

    @param _projectId The ID of the project to get total outstanding tokens of.

    @return The current total amount of outstanding tokens for the project.
  */
  function totalOutstandingTokensOf(uint256 _projectId) public view override returns (uint256) {
    // Add the reserved tokens to the total supply.
    return tokenStore.totalSupplyOf(_projectId) + _reservedTokenBalanceOf[_projectId];
  }

  /**
    @notice
    Indicates if this contract adheres to the specified interface.

    @dev 
    See {IERC165-supportsInterface}.

    @param _interfaceId The ID of the interface to check for adherance to.
  */
  function supportsInterface(bytes4 _interfaceId)
    public
    view
    virtual
    override(ERC165, IERC165)
    returns (bool)
  {
    return
      _interfaceId == type(IJBController3_0_1).interfaceId ||
      _interfaceId == type(IJBMigratable).interfaceId ||
      _interfaceId == type(IJBOperatable).interfaceId ||
      super.supportsInterface(_interfaceId);
  }

  //*********************************************************************//
  // ---------------------------- constructor -------------------------- //
  //*********************************************************************//

  /**
    @param _operatorStore A contract storing operator assignments.
    @param _projects A contract which mints ERC-721's that represent project ownership and transfers.
    @param _directory A contract storing directories of terminals and controllers for each project.
    @param _fundingCycleStore A contract storing all funding cycle configurations.
    @param _tokenStore A contract that manages token minting and burning.
    @param _splitsStore A contract that stores splits for each project.
  */
  constructor(
    IJBOperatorStore _operatorStore,
    IJBProjects _projects,
    IJBDirectory _directory,
    IJBFundingCycleStore _fundingCycleStore,
    IJBTokenStore _tokenStore,
    IJBSplitsStore _splitsStore
  ) JBOperatable(_operatorStore) {
    projects = _projects;
    directory = _directory;
    fundingCycleStore = _fundingCycleStore;
    tokenStore = _tokenStore;
    splitsStore = _splitsStore;
  }

  //*********************************************************************//
  // --------------------- external transactions ----------------------- //
  //*********************************************************************//

  /**
    @notice
    Creates a project. This will mint an ERC-721 into the specified owner's account, configure a first funding cycle, and set up any splits.

    @dev
    Each operation within this transaction can be done in sequence separately.

    @dev
    Anyone can deploy a project on an owner's behalf.

    @param _owner The address to set as the owner of the project. The project ERC-721 will be owned by this address.
    @param _projectMetadata Metadata to associate with the project within a particular domain. This can be updated any time by the owner of the project.
    @param _data Data that defines the project's first funding cycle. These properties will remain fixed for the duration of the funding cycle.
    @param _metadata Metadata specifying the controller specific params that a funding cycle can have. These properties will remain fixed for the duration of the funding cycle.
    @param _mustStartAtOrAfter The time before which the configured funding cycle cannot start.
    @param _groupedSplits An array of splits to set for any number of groups. 
    @param _fundAccessConstraints An array containing amounts that a project can use from its treasury for each payment terminal. Amounts are fixed point numbers using the same number of decimals as the accompanying terminal. The `_distributionLimit` and `_overflowAllowance` parameters must fit in a `uint232`.
    @param _terminals Payment terminals to add for the project.
    @param _memo A memo to pass along to the emitted event.

    @return projectId The ID of the project.
  */
  function launchProjectFor(
    address _owner,
    JBProjectMetadata calldata _projectMetadata,
    JBFundingCycleData calldata _data,
    JBFundingCycleMetadata calldata _metadata,
    uint256 _mustStartAtOrAfter,
    JBGroupedSplits[] calldata _groupedSplits,
    JBFundAccessConstraints[] calldata _fundAccessConstraints,
    IJBPaymentTerminal[] memory _terminals,
    string memory _memo
  ) external virtual override returns (uint256 projectId) {
    // Keep a reference to the directory.
    IJBDirectory _directory = directory;

    // Mint the project into the wallet of the owner.
    projectId = projects.createFor(_owner, _projectMetadata);

    // Set this contract as the project's controller in the directory.
    _directory.setControllerOf(projectId, address(this));

    // Configure the first funding cycle.
    uint256 _configuration = _configure(
      projectId,
      _data,
      _metadata,
      _mustStartAtOrAfter,
      _groupedSplits,
      _fundAccessConstraints
    );

    // Add the provided terminals to the list of terminals.
    if (_terminals.length > 0) _directory.setTerminalsOf(projectId, _terminals);

    emit LaunchProject(_configuration, projectId, _memo, msg.sender);
  }

  /**
    @notice
    Creates a funding cycle for an already existing project ERC-721.

    @dev
    Each operation within this transaction can be done in sequence separately.

    @dev
    Only a project owner or operator can launch its funding cycles.

    @param _projectId The ID of the project to launch funding cycles for.
    @param _data Data that defines the project's first funding cycle. These properties will remain fixed for the duration of the funding cycle.
    @param _metadata Metadata specifying the controller specific params that a funding cycle can have. These properties will remain fixed for the duration of the funding cycle.
    @param _mustStartAtOrAfter The time before which the configured funding cycle cannot start.
    @param _groupedSplits An array of splits to set for any number of groups. 
    @param _fundAccessConstraints An array containing amounts that a project can use from its treasury for each payment terminal. Amounts are fixed point numbers using the same number of decimals as the accompanying terminal. The `_distributionLimit` and `_overflowAllowance` parameters must fit in a `uint232`.
    @param _terminals Payment terminals to add for the project.
    @param _memo A memo to pass along to the emitted event.

    @return configuration The configuration of the funding cycle that was successfully created.
  */
  function launchFundingCyclesFor(
    uint256 _projectId,
    JBFundingCycleData calldata _data,
    JBFundingCycleMetadata calldata _metadata,
    uint256 _mustStartAtOrAfter,
    JBGroupedSplits[] calldata _groupedSplits,
    JBFundAccessConstraints[] memory _fundAccessConstraints,
    IJBPaymentTerminal[] memory _terminals,
    string memory _memo
  )
    external
    virtual
    override
    requirePermission(projects.ownerOf(_projectId), _projectId, JBOperations.RECONFIGURE)
    returns (uint256 configuration)
  {
    // If there is a previous configuration, reconfigureFundingCyclesOf should be called instead
    if (fundingCycleStore.latestConfigurationOf(_projectId) > 0)
      revert FUNDING_CYCLE_ALREADY_LAUNCHED();

    // Set this contract as the project's controller in the directory.
    directory.setControllerOf(_projectId, address(this));

    // Configure the first funding cycle.
    configuration = _configure(
      _projectId,
      _data,
      _metadata,
      _mustStartAtOrAfter,
      _groupedSplits,
      _fundAccessConstraints
    );

    // Add the provided terminals to the list of terminals.
    if (_terminals.length > 0) directory.setTerminalsOf(_projectId, _terminals);

    emit LaunchFundingCycles(configuration, _projectId, _memo, msg.sender);
  }

  /**
    @notice
    Proposes a configuration of a subsequent funding cycle that will take effect once the current one expires if it is approved by the current funding cycle's ballot.

    @dev
    Only a project's owner or a designated operator can configure its funding cycles.

    @param _projectId The ID of the project whose funding cycles are being reconfigured.
    @param _data Data that defines the funding cycle. These properties will remain fixed for the duration of the funding cycle.
    @param _metadata Metadata specifying the controller specific params that a funding cycle can have. These properties will remain fixed for the duration of the funding cycle.
    @param _mustStartAtOrAfter The time before which the configured funding cycle cannot start.
    @param _groupedSplits An array of splits to set for any number of groups. 
    @param _fundAccessConstraints An array containing amounts that a project can use from its treasury for each payment terminal. Amounts are fixed point numbers using the same number of decimals as the accompanying terminal. The `_distributionLimit` and `_overflowAllowance` parameters must fit in a `uint232`.
    @param _memo A memo to pass along to the emitted event.

    @return configuration The configuration of the funding cycle that was successfully reconfigured.
  */
  function reconfigureFundingCyclesOf(
    uint256 _projectId,
    JBFundingCycleData calldata _data,
    JBFundingCycleMetadata calldata _metadata,
    uint256 _mustStartAtOrAfter,
    JBGroupedSplits[] calldata _groupedSplits,
    JBFundAccessConstraints[] calldata _fundAccessConstraints,
    string calldata _memo
  )
    external
    virtual
    override
    requirePermission(projects.ownerOf(_projectId), _projectId, JBOperations.RECONFIGURE)
    returns (uint256 configuration)
  {
    // Configure the next funding cycle.
    configuration = _configure(
      _projectId,
      _data,
      _metadata,
      _mustStartAtOrAfter,
      _groupedSplits,
      _fundAccessConstraints
    );

    emit ReconfigureFundingCycles(configuration, _projectId, _memo, msg.sender);
  }

  /**
    @notice
    Mint new token supply into an account, and optionally reserve a supply to be distributed according to the project's current funding cycle configuration.

    @dev
    Only a project's owner, a designated operator, one of its terminals, or the current data source can mint its tokens.

    @param _projectId The ID of the project to which the tokens being minted belong.
    @param _tokenCount The amount of tokens to mint in total, counting however many should be reserved.
    @param _beneficiary The account that the tokens are being minted for.
    @param _memo A memo to pass along to the emitted event.
    @param _preferClaimedTokens A flag indicating whether a project's attached token contract should be minted if they have been issued.
    @param _useReservedRate Whether to use the current funding cycle's reserved rate in the mint calculation.

    @return beneficiaryTokenCount The amount of tokens minted for the beneficiary.
  */
  function mintTokensOf(
    uint256 _projectId,
    uint256 _tokenCount,
    address _beneficiary,
    string calldata _memo,
    bool _preferClaimedTokens,
    bool _useReservedRate
  )
    external
    virtual
    override
    returns (uint256 beneficiaryTokenCount)
  {
    // There should be tokens to mint.
    if (_tokenCount == 0) revert ZERO_TOKENS_TO_MINT();

    // Define variables that will be needed outside scoped section below.
    // Keep a reference to the reserved rate to use
    uint256 _reservedRate;

    // Scoped section prevents stack too deep. `_fundingCycle` only used within scope.
    {
      // Get a reference to the project's current funding cycle.
      JBFundingCycle memory _fundingCycle = fundingCycleStore.currentOf(_projectId);

      // Minting limited to: project owner, authorized callers, project terminal and current funding cycle data source
      _requirePermissionAllowingOverride(
        projects.ownerOf(_projectId),
        _projectId,
        JBOperations.MINT,
        directory.isTerminalOf(_projectId, IJBPaymentTerminal(msg.sender)) ||
          msg.sender == address(_fundingCycle.dataSource())
      );

      // If the message sender is not a terminal or a datasource, the current funding cycle must allow minting.
      if (
        !_fundingCycle.mintingAllowed() &&
        !directory.isTerminalOf(_projectId, IJBPaymentTerminal(msg.sender)) &&
        msg.sender != address(_fundingCycle.dataSource())
      ) revert MINT_NOT_ALLOWED_AND_NOT_TERMINAL_DELEGATE();

      // Determine the reserved rate to use.
      _reservedRate = _useReservedRate ? _fundingCycle.reservedRate() : 0;

      // Override the claimed token preference with the funding cycle value.
      _preferClaimedTokens = _preferClaimedTokens == true
        ? _preferClaimedTokens
        : _fundingCycle.preferClaimedTokenOverride();
    }

    if (_reservedRate != JBConstants.MAX_RESERVED_RATE) {
      // The unreserved token count that will be minted for the beneficiary.
      beneficiaryTokenCount = PRBMath.mulDiv(
        _tokenCount,
        JBConstants.MAX_RESERVED_RATE - _reservedRate,
        JBConstants.MAX_RESERVED_RATE
      );

      // Mint the tokens.
      tokenStore.mintFor(_beneficiary, _projectId, beneficiaryTokenCount, _preferClaimedTokens);
    }

    // Add reserved tokens if needed
    if (_reservedRate > 0)
      _reservedTokenBalanceOf[_projectId] += _tokenCount - beneficiaryTokenCount;

    emit MintTokens(
      _beneficiary,
      _projectId,
      _tokenCount,
      beneficiaryTokenCount,
      _memo,
      _reservedRate,
      msg.sender
    );
  }

  /**
    @notice
    Burns a token holder's supply.

    @dev
    Only a token's holder, a designated operator, or a project's terminal can burn it.

    @param _holder The account that is having its tokens burned.
    @param _projectId The ID of the project to which the tokens being burned belong.
    @param _tokenCount The number of tokens to burn.
    @param _memo A memo to pass along to the emitted event.
    @param _preferClaimedTokens A flag indicating whether a project's attached token contract should be burned first if they have been issued.
  */
  function burnTokensOf(
    address _holder,
    uint256 _projectId,
    uint256 _tokenCount,
    string calldata _memo,
    bool _preferClaimedTokens
  )
    external
    virtual
    override
    requirePermissionAllowingOverride(
      _holder,
      _projectId,
      JBOperations.BURN,
      directory.isTerminalOf(_projectId, IJBPaymentTerminal(msg.sender))
    )
  {
    // There should be tokens to burn
    if (_tokenCount == 0) revert NO_BURNABLE_TOKENS();

    // Get a reference to the project's current funding cycle.
    JBFundingCycle memory _fundingCycle = fundingCycleStore.currentOf(_projectId);

    // If the message sender is a terminal, the current funding cycle must not be paused.
    if (
      _fundingCycle.burnPaused() &&
      !directory.isTerminalOf(_projectId, IJBPaymentTerminal(msg.sender))
    ) revert BURN_PAUSED_AND_SENDER_NOT_VALID_TERMINAL_DELEGATE();

    // Burn the tokens.
    tokenStore.burnFrom(_holder, _projectId, _tokenCount, _preferClaimedTokens);

    emit BurnTokens(_holder, _projectId, _tokenCount, _memo, msg.sender);
  }

  /**
    @notice
    Distributes all outstanding reserved tokens for a project.

    @param _projectId The ID of the project to which the reserved tokens belong.
    @param _memo A memo to pass along to the emitted event.

    @return The amount of minted reserved tokens.
  */
  function distributeReservedTokensOf(uint256 _projectId, string calldata _memo)
    external
    virtual
    override
    returns (uint256)
  {
    return _distributeReservedTokensOf(_projectId, _memo);
  }

  /**
    @notice
    Allows other controllers to signal to this one that a migration is expected for the specified project.

    @dev
    This controller should not yet be the project's controller.

    @param _projectId The ID of the project that will be migrated to this controller.
    @param _from The controller being migrated from.
  */
  function prepForMigrationOf(uint256 _projectId, address _from) external virtual override {
    _projectId; // Prevents unused var compiler and natspec complaints.
    _from; // Prevents unused var compiler and natspec complaints.
  }

  /**
    @notice
    Allows a project to migrate from this controller to another.

    @dev
    Only a project's owner or a designated operator can migrate it.

    @param _projectId The ID of the project that will be migrated from this controller.
    @param _to The controller to which the project is migrating.
  */
  function migrate(uint256 _projectId, IJBMigratable _to)
    external
    virtual
    override
    requirePermission(projects.ownerOf(_projectId), _projectId, JBOperations.MIGRATE_CONTROLLER)
  {
    // Keep a reference to the directory.
    IJBDirectory _directory = directory;

    // This controller must be the project's current controller.
    if (_directory.controllerOf(_projectId) != address(this)) revert NOT_CURRENT_CONTROLLER();

    // Get a reference to the project's current funding cycle.
    JBFundingCycle memory _fundingCycle = fundingCycleStore.currentOf(_projectId);

    // Migration must be allowed.
    if (!_fundingCycle.controllerMigrationAllowed()) revert MIGRATION_NOT_ALLOWED();

    // All reserved tokens must be minted before migrating.
    if (_reservedTokenBalanceOf[_projectId] != 0) _distributeReservedTokensOf(_projectId, '');

    // Make sure the new controller is prepped for the migration.
    _to.prepForMigrationOf(_projectId, address(this));

    // Set the new controller.
    _directory.setControllerOf(_projectId, address(_to));

    emit Migrate(_projectId, _to, msg.sender);
  }

  //*********************************************************************//
  // ------------------------ internal functions ----------------------- //
  //*********************************************************************//

  /**
    @notice
    Distributes all outstanding reserved tokens for a project.

    @param _projectId The ID of the project to which the reserved tokens belong.
    @param _memo A memo to pass along to the emitted event.

    @return tokenCount The amount of minted reserved tokens.
  */
  function _distributeReservedTokensOf(uint256 _projectId, string memory _memo)
    internal
    returns (uint256 tokenCount)
  {
    // Keep a reference to the token store.
    IJBTokenStore _tokenStore = tokenStore;

    // Get the current funding cycle to read the reserved rate from.
    JBFundingCycle memory _fundingCycle = fundingCycleStore.currentOf(_projectId);

    // Get a reference to the number of tokens that need to be minted.
    tokenCount = _reservedTokenBalanceOf[_projectId];

    // Reset the reserved token balance
    _reservedTokenBalanceOf[_projectId] = 0;

    // Get a reference to the project owner.
    address _owner = projects.ownerOf(_projectId);

    // Distribute tokens to splits and get a reference to the leftover amount to mint after all splits have gotten their share.
    uint256 _leftoverTokenCount = tokenCount == 0
      ? 0
      : _distributeToReservedTokenSplitsOf(
        _projectId,
        _fundingCycle.configuration,
        JBSplitsGroups.RESERVED_TOKENS,
        tokenCount
      );

    // Mint any leftover tokens to the project owner.
    if (_leftoverTokenCount > 0)
      _tokenStore.mintFor(_owner, _projectId, _leftoverTokenCount, false);

    emit DistributeReservedTokens(
      _fundingCycle.configuration,
      _fundingCycle.number,
      _projectId,
      _owner,
      tokenCount,
      _leftoverTokenCount,
      _memo,
      msg.sender
    );
  }

  /**
    @notice
    Distribute tokens to the splits according to the specified funding cycle configuration.

    @param _projectId The ID of the project for which reserved token splits are being distributed.
    @param _domain The domain of the splits to distribute the reserved tokens between.
    @param _group The group of the splits to distribute the reserved tokens between.
    @param _amount The total amount of tokens to mint.

    @return leftoverAmount If the splits percents dont add up to 100%, the leftover amount is returned.
  */
  function _distributeToReservedTokenSplitsOf(
    uint256 _projectId,
    uint256 _domain,
    uint256 _group,
    uint256 _amount
  ) internal returns (uint256 leftoverAmount) {
    // Keep a reference to the token store.
    IJBTokenStore _tokenStore = tokenStore;

    // Set the leftover amount to the initial amount.
    leftoverAmount = _amount;

    // Get a reference to the project's reserved token splits.
    JBSplit[] memory _splits = splitsStore.splitsOf(_projectId, _domain, _group);

    //Transfer between all splits.
    for (uint256 _i; _i < _splits.length; ) {
      // Get a reference to the split being iterated on.
      JBSplit memory _split = _splits[_i];

      // The amount to send towards the split.
      uint256 _tokenCount = PRBMath.mulDiv(
        _amount,
        _split.percent,
        JBConstants.SPLITS_TOTAL_PERCENT
      );

      // Mints tokens for the split if needed.
      if (_tokenCount > 0) {
        _tokenStore.mintFor(
          // If an allocator is set in the splits, set it as the beneficiary.
          // Otherwise if a projectId is set in the split, set the project's owner as the beneficiary.
          // If the split has a beneficiary send to the split's beneficiary. Otherwise send to the msg.sender.
          _split.allocator != IJBSplitAllocator(address(0))
            ? address(_split.allocator)
            : _split.projectId != 0
            ? projects.ownerOf(_split.projectId)
            : _split.beneficiary != address(0)
            ? _split.beneficiary
            : msg.sender,
          _projectId,
          _tokenCount,
          _split.preferClaimed
        );

        // If there's an allocator set, trigger its `allocate` function.
        if (_split.allocator != IJBSplitAllocator(address(0)))
          _split.allocator.allocate(
            JBSplitAllocationData(
              address(_tokenStore.tokenOf(_projectId)),
              _tokenCount,
              18,
              _projectId,
              _group,
              _split
            )
          );

        // Subtract from the amount to be sent to the beneficiary.
        leftoverAmount = leftoverAmount - _tokenCount;
      }

      emit DistributeToReservedTokenSplit(
        _projectId,
        _domain,
        _group,
        _split,
        _tokenCount,
        msg.sender
      );

      unchecked {
        ++_i;
      }
    }
  }

  /**
    @notice
    Configures a funding cycle and stores information pertinent to the configuration.

    @param _projectId The ID of the project whose funding cycles are being reconfigured.
    @param _data Data that defines the funding cycle. These properties will remain fixed for the duration of the funding cycle.
    @param _metadata Metadata specifying the controller specific params that a funding cycle can have. These properties will remain fixed for the duration of the funding cycle.
    @param _mustStartAtOrAfter The time before which the configured funding cycle cannot start.
    @param _groupedSplits An array of splits to set for any number of groups. 
    @param _fundAccessConstraints An array containing amounts that a project can use from its treasury for each payment terminal. Amounts are fixed point numbers using the same number of decimals as the accompanying terminal.

    @return configuration The configuration of the funding cycle that was successfully reconfigured.
  */
  function _configure(
    uint256 _projectId,
    JBFundingCycleData calldata _data,
    JBFundingCycleMetadata calldata _metadata,
    uint256 _mustStartAtOrAfter,
    JBGroupedSplits[] memory _groupedSplits,
    JBFundAccessConstraints[] memory _fundAccessConstraints
  ) internal returns (uint256) {
    // Make sure the provided reserved rate is valid.
    if (_metadata.reservedRate > JBConstants.MAX_RESERVED_RATE) revert INVALID_RESERVED_RATE();

    // Make sure the provided redemption rate is valid.
    if (_metadata.redemptionRate > JBConstants.MAX_REDEMPTION_RATE)
      revert INVALID_REDEMPTION_RATE();

    // Make sure the provided ballot redemption rate is valid.
    if (_metadata.ballotRedemptionRate > JBConstants.MAX_REDEMPTION_RATE)
      revert INVALID_BALLOT_REDEMPTION_RATE();

    // Configure the funding cycle's properties.
    JBFundingCycle memory _fundingCycle = fundingCycleStore.configureFor(
      _projectId,
      _data,
      JBFundingCycleMetadataResolver.packFundingCycleMetadata(_metadata),
      _mustStartAtOrAfter
    );

    // Set splits for the group.
    splitsStore.set(_projectId, _fundingCycle.configuration, _groupedSplits);

    // Set distribution limits if there are any.
    for (uint256 _i; _i < _fundAccessConstraints.length; ) {
      JBFundAccessConstraints memory _constraints = _fundAccessConstraints[_i];

      // If distribution limit value is larger than 232 bits, revert.
      if (_constraints.distributionLimit > type(uint232).max) revert INVALID_DISTRIBUTION_LIMIT();

      // If distribution limit currency value is larger than 24 bits, revert.
      if (_constraints.distributionLimitCurrency > type(uint24).max)
        revert INVALID_DISTRIBUTION_LIMIT_CURRENCY();

      // If overflow allowance value is larger than 232 bits, revert.
      if (_constraints.overflowAllowance > type(uint232).max) revert INVALID_OVERFLOW_ALLOWANCE();

      // If overflow allowance currency value is larger than 24 bits, revert.
      if (_constraints.overflowAllowanceCurrency > type(uint24).max)
        revert INVALID_OVERFLOW_ALLOWANCE_CURRENCY();

      // Set the distribution limit if there is one.
      if (_constraints.distributionLimit > 0)
        _packedDistributionLimitDataOf[_projectId][_fundingCycle.configuration][
          _constraints.terminal
        ][_constraints.token] =
          _constraints.distributionLimit |
          (_constraints.distributionLimitCurrency << 232);

      // Set the overflow allowance if there is one.
      if (_constraints.overflowAllowance > 0)
        _packedOverflowAllowanceDataOf[_projectId][_fundingCycle.configuration][
          _constraints.terminal
        ][_constraints.token] =
          _constraints.overflowAllowance |
          (_constraints.overflowAllowanceCurrency << 232);

      emit SetFundAccessConstraints(
        _fundingCycle.configuration,
        _fundingCycle.number,
        _projectId,
        _constraints,
        msg.sender
      );

      unchecked {
        ++_i;
      }
    }

    return _fundingCycle.configuration;
  }
}
