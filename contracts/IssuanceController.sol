/*
-----------------------------------------------------------------
FILE INFORMATION
-----------------------------------------------------------------

file:       IssuanceController.sol
version:    2.0
author:     Kevin Brown
date:       2018-07-18

-----------------------------------------------------------------
MODULE DESCRIPTION
-----------------------------------------------------------------

Issuance controller contract. The issuance controller provides
a way for users to acquire nomins (Nomin.sol) and havvens
(Havven.sol) by paying ETH and a way for users to acquire havvens
(Havven.sol) by paying nomins.

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

    // Address where the ether and Nomins raised for selling HAV is transfered to
    // Any ether raised for selling Nomins gets sent back to whoever deposited the Nomins,
    // and doesn't have anything to do with this address.
    address public fundsWallet;

    /* The address of the oracle which pushes the USD price havvens and ether to this contract */
    address public oracle;
    /* Do not allow the oracle to submit times any further forward into the future than
       this constant. */
    uint constant ORACLE_FUTURE_LIMIT = 10 minutes;

    /* How long will the contract assume the price of any asset is correct */
    uint public priceStalePeriod = 3 hours;

    /* The time the prices were last updated */
    uint public lastPriceUpdateTime;
    /* The USD price of havvens denominated in UNIT */
    uint public usdToHavPrice;
    /* The USD price of ETH denominated in UNIT */
    uint public usdToEthPrice;
    
    /* Stores deposits from users. */
    struct nominDeposit {
        // The user that made the deposit
        address user;
        // The amount (in Nomins) that they deposited
        uint amount;
    }

    /* User deposits are sold on a FIFO (First in First out) basis. When users deposit
       nomins with us, they get added this queue, which then gets fulfilled in order.
       Conceptually this fits well in an array, but then when users fill an order we
       end up copying the whole array around, so better to use an index mapping instead
       for gas performance reasons.
       
       The indexes are specified (inclusive, exclusive), so (0, 0) means there's nothing
       in the array, and (3, 6) means there are 3 elements at 3, 4, and 5. You can obtain
       the length of the "array" by querying depositEndIndex - depositStartIndex. All index
       operations use safeAdd, so there is no way to overflow, so that means there is a
       very large but finite amount of deposits this contract can handle before it fills up. */
    mapping(uint => nominDeposit) public deposits;
    // The starting index of our queue inclusive
    uint public depositStartIndex;
    // The ending index of our queue exclusive
    uint public depositEndIndex;

    /* This is a convenience variable so users and dApps can just query how much nUSD
       we have available for purchase without having to iterate the mapping with a
       O(n) amount of calls for something we'll probably want to display quite regularly. */
    uint public totalSellableDeposits;

    /* ========== CONSTRUCTOR ========== */

    /**
     * @dev Constructor
     * @param _owner The owner of this contract.
     * @param _havven The Havven contract we'll interact with for balances and sending.
     * @param _nomin The Nomin contract we'll interact with for balances and sending.
     * @param _oracle The address which is able to update price information.
     * @param _usdToEthPrice The current price of ETH in USD, expressed in UNIT.
     * @param _usdToHavPrice The current price of Havven in USD, expressed in UNIT.
     */
    constructor(
        // Ownable
        address _owner,

        // Funds Wallet
        address _fundsWallet,

        // Other contracts needed
        Havven _havven,
        Nomin _nomin,

        // Oracle values - Allows for price updates
        address _oracle,
        uint _usdToEthPrice,
        uint _usdToHavPrice
    )
        /* Owned is initialised in SelfDestructible */
        SelfDestructible(_owner)
        Pausable(_owner)
        public
    {
        fundsWallet = _fundsWallet;
        havven = _havven;
        nomin = _nomin;
        oracle = _oracle;
        usdToEthPrice = _usdToEthPrice;
        usdToHavPrice = _usdToHavPrice;
        lastPriceUpdateTime = now;
        totalSellableDeposits = 0;
    }

    /* ========== SETTERS ========== */

    /**
     * @notice Set the funds wallet where ETH raised is held
     */
    function setFundsWallet(address _fundsWallet)
        external
        onlyOwner
    {
        fundsWallet = _fundsWallet;
        emit FundsWalletUpdated(fundsWallet);
    }
    
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
     * @notice Set the Nomin contract that the issuance controller uses to issue Nomins.
     */
    function setNomin(Nomin _nomin)
        external
        onlyOwner
    {
        nomin = _nomin;
        emit NominUpdated(_nomin);
    }

    /**
     * @notice Set the Havven contract that the issuance controller uses to issue Havvens.
     */
    function setHavven(Havven _havven)
        external
        onlyOwner
    {
        havven = _havven;
        emit HavvenUpdated(_havven);
    }

    /**
     * @notice Set the stale period on the updated price variables
     */
    function setPriceStalePeriod(uint _time)
        external
        onlyOwner 
    {
        priceStalePeriod = _time;
        emit PriceStalePeriodUpdated(priceStalePeriod);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    /**
     * @notice Access point for the oracle to update the prices of havvens / eth.
     */
    function updatePrices(uint newEthPrice, uint newHavvenPrice, uint timeSent)
        external
        onlyOracle
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
     * @notice Fallback function (exchanges ETH to nUSD)
     */
    function ()
        external
        payable
    {
        exchangeEtherForNomins();
    } 

    event Log(string message);
    event LogInt(string message, uint number);
    event LogAddress(string message, address addr);

    /**
     * @notice Exchange ETH to nUSD.
     */
    function exchangeEtherForNomins()
        public 
        payable
        pricesNotStale
        notPaused
        returns (uint) // Returns the number of Nomins (nUSD) received
    {
        // The multiplication works here because usdToEthPrice is specified in
        // 18 decimal places, just like our currency base.
        uint requestedToPurchase = safeMul_dec(msg.value, usdToEthPrice);
        emit LogInt("Requested to purchase", requestedToPurchase);
        uint remainingToFulfill = requestedToPurchase;
        emit LogInt("Remaining to fulfill", remainingToFulfill);

        // Iterate through our outstanding deposits and sell them one at a time.
        for (uint i = depositStartIndex; remainingToFulfill > 0 && i < depositEndIndex; i++) {
            nominDeposit memory deposit = deposits[i];

            emit LogAddress("Deposit address", deposit.user);
            emit LogInt("Deposit amount", deposit.amount);

            // If it's an empty spot in the queue from a previous withdrawal, just skip over it and
            // update the queue. It's already been deleted.
            if (deposit.user == address(0)) {
                emit LogInt("Queue spot is already deleted, skipping", i);

                depositStartIndex = safeAdd(depositStartIndex, 1);
                emit LogInt("New start index", depositStartIndex);
            } else {
                // If the deposit can more than fill the order, we can do this
                // without touching the structure of our queue.
                if (deposit.amount > remainingToFulfill) {
                    emit Log("Fulfilling from first deposit");

                    // Ok, this deposit can fulfill the whole remainder. We don't need
                    // to change anything about our queue we can just fulfill it.
                    // Subtract the amount from our deposit and total.
                    deposit.amount = safeSub(deposit.amount, remainingToFulfill);
                    totalSellableDeposits = safeSub(totalSellableDeposits, remainingToFulfill);

                    emit LogInt("New deposit amount", deposit.amount);
                    emit LogInt("New total sellable", totalSellableDeposits);
                    
                    // Transfer the ETH to the depositor.
                    deposit.user.transfer(safeDiv_dec(remainingToFulfill, usdToEthPrice));
                    emit LogInt("Transferring ETH", safeDiv_dec(remainingToFulfill, usdToEthPrice));
                    // And the Nomins to the recipient.
                    // Note: Fees are calculated by the Nomin contract, so when 
                    //       we request a specific transfer here, the fee is
                    //       automatically deducted and sent to the fee pool.
                    nomin.transfer(msg.sender, remainingToFulfill);
                    emit LogInt("Amount of Nomins transferred", remainingToFulfill);

                    // And we have nothing left to fulfill on this order.
                    remainingToFulfill = 0;
                } else if (deposit.amount <= remainingToFulfill) {
                    emit LogInt("Deposit amount", deposit.amount);
                    emit LogInt("Remaining to fulfill", remainingToFulfill);
                    emit Log("Amount exceeds first deposit, consuming");
                    // We need to fulfill this one in its entirety and kick it out of the queue.
                    // Start by kicking it out of the queue.
                    // Free the storage because we can.
                    delete deposits[i];
                    // Bump our start index forward one.
                    depositStartIndex = safeAdd(depositStartIndex, 1);
                    // We also need to tell our total it's decreased
                    totalSellableDeposits = safeSub(totalSellableDeposits, deposit.amount);
                    emit LogInt("New start index", depositStartIndex);
                    emit LogInt("New end index", depositStartIndex);
                    emit LogInt("New queue length", depositEndIndex - depositStartIndex);
                    emit LogInt("New total", totalSellableDeposits);

                    // Now fulfill by transfering the ETH to the depositor.
                    deposit.user.transfer(safeDiv_dec(deposit.amount, usdToEthPrice));
                    emit LogInt("Transferring ETH", safeDiv_dec(deposit.amount, usdToEthPrice));
                    // And the Nomins to the recipient.
                    // Note: Fees are calculated by the Nomin contract, so when 
                    //       we request a specific transfer here, the fee is
                    //       automatically deducted and sent to the fee pool.
                    nomin.transfer(msg.sender, deposit.amount);
                    emit LogInt("Transferring Nomins", deposit.amount);

                    // And subtract the order from our outstanding amount remaining
                    // for the next iteration of the loop.
                    remainingToFulfill = safeSub(remainingToFulfill, deposit.amount);
                    emit LogInt("New remaining to fulfill", remainingToFulfill);
                }
            }
        }

        // Ok, if we're here and 'remainingToFulfill' isn't zero, then
        // we need to refund the remainder of their ETH back to them.
        if (remainingToFulfill > 0) {
            msg.sender.transfer(safeDiv_dec(remainingToFulfill, usdToEthPrice));
        }

        // How many did we actually give them?
        uint fulfilled = safeSub(requestedToPurchase, remainingToFulfill);

        // Now tell everyone that we gave them that many.
        emit Exchange("ETH", msg.value, "nUSD", fulfilled);

        return fulfilled;
    }

    /**
     * @notice Exchange ETH to nUSD while insisting on a particular rate. This allows a user to
     *         exchange while protecting against frontrunning by the contract owner on the exchange rate.
     * @param guaranteedRate The exchange rate which must be honored or the call will revert.
     */
    function exchangeEtherForNominsAtRate(uint guaranteedRate)
        public
        payable
        pricesNotStale
        notPaused
        returns (uint) // Returns the number of Nomins (nUSD) received
    {
        require(guaranteedRate == usdToEthPrice);

        return exchangeEtherForNomins();
    }


    /**
     * @notice Exchange ETH to HAV.
     */
    function exchangeEtherForHavvens()
        public 
        payable
        pricesNotStale
        notPaused
        returns (uint) // Returns the number of Havvens (HAV) received
    {
        // How many Havvens are they going to be receiving?
        uint havvensToSend = havvensReceivedForEther(msg.value);

        // Store the ETH in our funds wallet
        fundsWallet.transfer(msg.value);

        // And send them the Havvens.
        havven.transfer(msg.sender, havvensToSend);

        emit Exchange("ETH", msg.value, "HAV", havvensToSend);

        return havvensToSend;
    }

    /**
     * @notice Exchange ETH to HAV while insisting on a particular set of rates. This allows a user to
     *         exchange while protecting against frontrunning by the contract owner on the exchange rates.
     * @param guaranteedEtherRate The ether exchange rate which must be honored or the call will revert.
     * @param guaranteedHavvenRate The havven exchange rate which must be honored or the call will revert.
     */
    function exchangeEtherForHavvensAtRate(uint guaranteedEtherRate, uint guaranteedHavvenRate)
        public
        payable
        pricesNotStale
        notPaused
        returns (uint) // Returns the number of Havvens (HAV) received
    {
        require(guaranteedEtherRate == usdToEthPrice);
        require(guaranteedHavvenRate == usdToHavPrice);

        return exchangeEtherForHavvens();
    }


    /**
     * @notice Exchange nUSD for Havvens
     * @param nominAmount The amount of nomins the user wishes to exchange.
     */
    function exchangeNominsForHavvens(uint nominAmount)
        public 
        pricesNotStale
        notPaused
        returns (uint) // Returns the number of Havvens (HAV) received
    {
        // How many Havvens are they going to be receiving?
        uint havvensToSend = havvensReceivedForNomins(nominAmount);
        
        // Ok, transfer the Nomins to our funds wallet.
        // These do not go in the deposit queue as they aren't for sale as such unless
        // they're sent back in from the funds wallet.
        nomin.transferFrom(msg.sender, fundsWallet, nominAmount);

        // And send them the Havvens.
        havven.transfer(msg.sender, havvensToSend);

        emit Exchange("nUSD", nominAmount, "HAV", havvensToSend);

        return havvensToSend; 
    }

    /**
     * @notice Exchange nUSD for Havvens while insisting on a particular rate. This allows a user to
     *         exchange while protecting against frontrunning by the contract owner on the exchange rate.
     * @param nominAmount The amount of nomins the user wishes to exchange.
     */
    function exchangeNominsForHavvensAtRate(uint nominAmount, uint guaranteedRate)
        public 
        pricesNotStale
        notPaused
        returns (uint) // Returns the number of Havvens (HAV) received
    {
        require(guaranteedRate == usdToHavPrice);

        return exchangeNominsForHavvens(nominAmount);
    }
    
    /**
     * @notice Withdraw havvens: Allows the owner to withdraw havvens from this contract if needed.
     */
    function withdrawHavvens(uint amount)
        external
        onlyOwner
    {
        havven.transfer(owner, amount);
        
        // We don't emit our own events here because we assume that anyone
        // who wants to watch what the Issuance Controller is doing can
        // just watch ERC20 events from the Nomin and/or Havven contracts
        // filtered to our address.
    }

    /**
     * @notice Withdraw all nomins: Allows a user to withdraw all of their nomins from this contract if needed.
     *         Developer note: We could keep an index of address to deposits to make this operation more efficient
     *         but then all the other operations on the queue become less efficient. It's expected that this
     *         function will be very rarely used, so placing the inefficiency here is intentional. The usual
     *         use case does not involve a withdrawal.
     */
    function withdrawMyDepositedNomins()
        external
    {
        uint nominsToSend = 0;

        for (uint i = depositStartIndex; i < depositEndIndex; i++) {
            nominDeposit memory deposit = deposits[i];

            if (deposit.user == msg.sender) {
                // The user is withdrawing this deposit. Remove it from our queue.
                // We'll just leave a gap, which the purchasing logic can walk past.
                nominsToSend = safeAdd(nominsToSend, deposit.amount);
                delete deposits[i];
            }
        }

        // If there's nothing to do then go ahead and revert the transaction
        require(nominsToSend > 0, "You have no deposits to withdraw.");

        // Update our total
        totalSellableDeposits = safeSub(totalSellableDeposits, nominsToSend);

        // Send their deposits back to them (minus fees)
        nomin.transfer(msg.sender, nominsToSend);
        
        emit NominWithdrawal(msg.sender, nominsToSend);
    }

    /**
     * @notice depositNomins: Allows users to deposit nomins via the approve / transferFrom workflow
     *         if they'd like. You can equally just transfer nomins to this contract and it will work
     *         exactly the same way but with one less call (and therefore cheaper transaction fees)
     * @param amount The amount of nUSD you wish to deposit (must have been authorised first)
     */
    function depositNomins(uint amount)
        external
    {
        // Grab the amount of nomins
        nomin.transferFrom(msg.sender, this, amount);

        // Note, we don't need to add them to the deposit list below, as the Nomin contract itself will
        // call havvenTokenFallback when the transfer happens, adding their deposit to the queue.
    }

    /**
     * @notice havvenTokenFallback: Triggers when users send us HAV or nUSD, but the modifier only allows nUSD
     *         calls to proceed.
     * @param from The address sending the nUSD
     * @param amount The amount of nUSD
     */
    function havvenTokenFallback(address from, uint amount)
        external
        onlyNomin
    {
        // Ok, thanks for the deposit, let's queue it up.
        deposits[depositEndIndex] = nominDeposit({ user: from, amount: amount });
        // Walk our index forward as well.
        depositEndIndex = safeAdd(depositEndIndex, 1);

        // And add it to our total.
        totalSellableDeposits = safeAdd(totalSellableDeposits, amount);
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

    /**
     * @notice Calculate how many havvens you will receive if you transfer
     *         an amount of nomins.
     */
    function havvensReceivedForNomins(uint amount)
        public 
        view
        returns (uint)
    {
        uint nominsReceived = nomin.amountReceived(amount);
        return safeDiv_dec(nominsReceived, usdToHavPrice);
    }

    /**
     * @notice Calculate how many havvens you will receive if you transfer
     *         an amount of ether (in wei).
     */
    function havvensReceivedForEther(uint amount)
        public 
        view
        returns (uint)
    {
        // First off, how much is the ETH they sent us worth in nUSD (ignoring the transfer fee)?
        uint valueSentInNomins = safeMul_dec(amount, usdToEthPrice); 

        // Now, how many HAV will that USD amount buy?
        return havvensReceivedForNomins(valueSentInNomins);
    }

    /**
     * @notice Calculate how many nomins you will receive if you transfer
     *         an amount of ether.
     */
    function nominsReceivedForEther(uint amount)
        public 
        view
        returns (uint)
    {
        uint nominsTransferred = safeMul_dec(amount, usdToEthPrice);
        return nomin.amountReceived(nominsTransferred);
    }
    
    /* ========== MODIFIERS ========== */

    modifier onlyOracle
    {
        require(msg.sender == oracle, "Only the oracle can perform this action");
        _;
    }

    modifier onlyNomin
    {
        // We're only interested in doing anything on receiving nUSD.
        require(msg.sender == address(nomin), "Only the nomin contract can perform this action");
        _;
    }

    modifier pricesNotStale
    {
        require(!pricesAreStale(), "Action cannot be performed while prices are stale");
        _;
    }

    /* ========== EVENTS ========== */

    event FundsWalletUpdated(address newFundsWallet);
    event OracleUpdated(address newOracle);
    event NominUpdated(Nomin newNominContract);
    event HavvenUpdated(Havven newHavvenContract);
    event PriceStalePeriodUpdated(uint priceStalePeriod);
    event PricesUpdated(uint newEthPrice, uint newHavvenPrice, uint timeSent);
    event Exchange(string fromCurrency, uint fromAmount, string toCurrency, uint toAmount);
    event NominWithdrawal(address user, uint amount);
}
