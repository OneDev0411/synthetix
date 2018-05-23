/*
-----------------------------------------------------------------
FILE INFORMATION
-----------------------------------------------------------------

file:       IssuanceController.sol
version:    0.1
author:     Kevin Brown

date:       2018-05-20

checked:    
approved:   

-----------------------------------------------------------------
MODULE DESCRIPTION
-----------------------------------------------------------------

Issuance controler contract. The issuance controller provides
a way for users to acquire Nomins (Nomin.sol) by paying ETH
and a way for users to acquire Havens (Havven.sol) by paying
Nomins.

This smart contract contains a balance of each currency, and
allows the owner of the contract (the Havven Foundation) to
manage the available balances of both currencies at their 
discretion.

In future releases this functionality will gradually move away
from a centralised approach with the Havven foundation
controlling all of the currency to a decentralised exchange
approach where users can exchange these assets freely.

-----------------------------------------------------------------
*/

pragma solidity 0.4.24;

import "contracts/SelfDestructible.sol";
import "contracts/Pausable.sol";
import "contracts/SafeDecimalMath.sol";
import "contracts/Havven.sol";
import "contracts/Nomin.sol";

/**
 * @title Issuance Controller Contract.
 */
contract IssuanceController is SafeDecimalMath, SelfDestructible, Pausable {

    /* ========== STATE VARIABLES ========== */
    Havven public havven;
    Nomin public nomin;

    /* The address of the oracle which pushes the havven price to this contract */
    address public oracle;
    /* Do not allow the oracle to submit times any further forward into the future than
       this constant. */
    uint constant ORACLE_FUTURE_LIMIT = 10 minutes;

    /* How long will the contract assume the price of any asset is correct */
    uint public priceStalePeriod = 3 hours;

    /* The time the prices were last updated */
    uint public lastPriceUpdateTime;
    /* The USD price of havvens written in UNIT */
    uint public usdToHavPrice;
    /* The USD price of ETH written in UNIT */
    uint public usdToEthPrice;
    
    uint public conversionFee;

    /* ========== CONSTRUCTOR ========== */

    /**
     * @dev Constructor
     * @param _owner The owner of this contract.
     * @param _beneficiary The address which will receive any ether upon self destruct completion.
     * @param _selfDestructDelay The timeframe from request of self destruct to ability to destroy.
     * @param _havven The Havven contract we'll interact with for balances and sending.
     * @param _nomin The Nomin contract we'll interact with for balances and sending.
     * @param _oracle The address which is able to update price information.
     * @param _usdToEthPrice The current price of ETH in USD, expressed in UNIT.
     * @param _usdToHavPrice The current price of Havven in USD, expressed in UNIT.
     */
    constructor(
        // Ownable
        address _owner,

        // SelfDestructable
        address _beneficiary,
        uint _selfDestructDelay,

        // Other contracts needed
        Havven _havven,
        Nomin _nomin,

        // Our own state variables
        address _oracle,
        uint _usdToEthPrice,
        uint _usdToHavPrice
    )
        /* Owned is initialised in SelfDestructible */
        SelfDestructible(_owner, _beneficiary, _selfDestructDelay)
        Pausable(_owner)
        public
    {
        havven = _havven;
        nomin = _nomin;
        oracle = _oracle;
        usdToEthPrice = _usdToEthPrice;
        usdToHavPrice = _usdToHavPrice;
        lastPriceUpdateTime = now;
    }

    /* ========== SETTERS ========== */

    /**
     * @notice Set the Oracle that pushes the havven price to this contract
     */
    function setOracle(address _oracle)
        external
        onlyOwner
    {
        oracle = _oracle;

        emit OracleUpdated(oracle);
    }

    /**
     * @notice Set the stale period on the updated price variables
     */
    function setPriceStalePeriod(uint _time)
        external
        onlyOwner 
    {
        priceStalePeriod = _time;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    /**
     * @notice Access point for the oracle to update the prices of havvens / eth.
     */
    function updatePrices(uint newEthPrice, uint newHavvenPrice, uint timeSent)
        external
        onlyOracle  /* Should be callable only by the oracle. */
    {
        /* Must be the most recently sent price, but not too far in the future.
         * (so we can't lock ourselves out of updating the oracle for longer than this) */
        require(lastPriceUpdateTime < timeSent && timeSent < now + ORACLE_FUTURE_LIMIT);

        usdToEthPrice = newEthPrice;
        usdToHavPrice = newHavvenPrice;
        lastPriceUpdateTime = timeSent;

        emit PricesUpdated(usdToEthPrice, usdToHavPrice, lastPriceUpdateTime);
    }

    /**
     * @notice Purchase nUSD with ETH.
     */
    function buyWithEth()
        public
        payable
        pricesNotStale // We can only do this when the prices haven't gone stale
        notPaused // And if the contract is paused we can't do this action either
        returns (uint) // Returns the number of Nomins (nUSD) received
    {
        // How many Nomins are available for us to sell?
        uint availableNomins = nomin.balanceOf(this);
        uint requestedToPurchase = msg.value * usdToEthPrice;

        // Ensure we are only sending ones we have allocated to us.
        // This check is technically not required because the Nomin
        // contract should enforce this as well.
        require(availableNomins >= requestedToPurchase);

        // Send the nomins.
        // Note: Fees are calculated by the Nomin contract, so when 
        //       we request a specific transfer here, the fee is
        //       automatically deducted and sent to the fee pool.
        nomin.transfer(msg.sender, requestedToPurchase);

        return requestedToPurchase;
    }


    /* ========== VIEWS ========== */
    /**
     * @notice Check if the prices haven't been updated for longer than the stale period.
     */
    function pricesAreStale()
        public
        view
        returns (bool)
    {
        return safeAdd(lastPriceUpdateTime, priceStalePeriod) < now;
    }

    /* ========== MODIFIERS ========== */

    modifier onlyOracle
    {
        require(msg.sender == oracle);
        _;
    }

    modifier pricesNotStale
    {
        require(!pricesAreStale());
        _;
    }

    /* ========== EVENTS ========== */

    event PricesUpdated(uint newEthPrice, uint newHavvenPrice, uint timeSent);
    event OracleUpdated(address newOracle);
}
