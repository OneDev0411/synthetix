/*
-----------------------------------------------------------------
FILE INFORMATION
-----------------------------------------------------------------

file:       ExternStateFeeToken.sol
version:    1.1
author:     Anton Jurisevic
            Dominic Romanowski

date:       2018-05-15

checked:    Mike Spain
approved:   Samuel Brooks

-----------------------------------------------------------------
MODULE DESCRIPTION
-----------------------------------------------------------------

A token which also has a configurable fee rate
charged on its transfers. This is designed to be overridden in
order to produce an ERC20-compliant token.

These fees accrue into a pool, from which a nominated authority
may withdraw.

This contract utilises a state for upgradability purposes.

-----------------------------------------------------------------
*/

pragma solidity 0.4.24;


import "contracts/SafeDecimalMath.sol";
import "contracts/Proxyable.sol";
import "contracts/TokenState.sol";


/**
 * @title ERC20 Token contract, with detached state.
 * Additionally charges fees on each transfer.
 */
contract ExternStateFeeToken is Proxyable, SafeDecimalMath {

    /* ========== STATE VARIABLES ========== */

    /* Stores balances and allowances. */
    TokenState public state;

    /* Other ERC20 fields.
     * Note that the decimals field is defined in SafeDecimalMath. */
    string public name;
    string public symbol;
    uint public totalSupply;

    /* A percentage fee charged on each transfer. */
    uint public transferFeeRate;
    /* Fee may not exceed 10%. */
    uint constant MAX_TRANSFER_FEE_RATE = UNIT / 10;
    /* The address with the authority to distribute fees. */
    address public feeAuthority;


    /* ========== CONSTRUCTOR ========== */

    /**
     * @dev Constructor.
     * @param _name Token's ERC20 name.
     * @param _symbol Token's ERC20 symbol.
     * @param _transferFeeRate The fee rate to charge on transfers.
     * @param _feeAuthority The address which has the authority to withdraw fees from the accumulated pool.
     * @param _owner The owner of this contract.
     */
    constructor(address _proxy, string _name, string _symbol, uint _transferFeeRate, address _feeAuthority,
                address _owner)
        Proxyable(_proxy, _owner)
        public
    {
        name = _name;
        symbol = _symbol;
        feeAuthority = _feeAuthority;
        state = new TokenState(_owner, address(this));

        /* Constructed transfer fee rate should respect the maximum fee rate. */
        require(_transferFeeRate <= MAX_TRANSFER_FEE_RATE);
        transferFeeRate = _transferFeeRate;
    }

    /* ========== SETTERS ========== */

    /**
     * @notice Set the transfer fee, anywhere within the range 0-10%.
     * @dev The fee rate is in decimal format, with UNIT being the value of 100%.
     */
    function setTransferFeeRate(uint _transferFeeRate)
        external
        optionalProxy_onlyOwner
    {
        require(_transferFeeRate <= MAX_TRANSFER_FEE_RATE);
        transferFeeRate = _transferFeeRate;
        emitTransferFeeRateUpdated(_transferFeeRate);
    }

    /**
     * @notice Set the address of the user/contract responsible for collecting or
     * distributing fees.
     */
    function setFeeAuthority(address _feeAuthority)
        public
        optionalProxy_onlyOwner
    {
        feeAuthority = _feeAuthority;
        emitFeeAuthorityUpdated(_feeAuthority);
    }

    /**
     * @notice Set the address of the state contract.
     * @dev This can be used to "pause" transfer functionality, by pointing the state at 0x000..
     * as balances would be unreachable
     */
    function setState(TokenState _state)
        external
        optionalProxy_onlyOwner
    {
        state = _state;
        emitStateUpdated(_state);
    }

    /* ========== VIEWS ========== */

    /**
     * @notice Query an account's balance from the state
     */
    function balanceOf(address account)
        public
        view
        returns (uint)
    {
        return state.balanceOf(account);
    }

    /**
     * @notice Query an account's balance from the state
     */
    function allowance(address from, address to)
        public
        view
        returns (uint)
    {
        return state.allowance(from, to);
    }

    /**
     * @notice Calculate the Fee charged on top of a value being sent
     * @return Return the fee charged
     */
    function transferFeeIncurred(uint value)
        public
        view
        returns (uint)
    {
        return safeMul_dec(value, transferFeeRate);
        /* Transfers less than the reciprocal of transferFeeRate should be completely eaten up by fees.
         * This is on the basis that transfers less than this value will result in a nil fee.
         * Probably too insignificant to worry about, but the following code will achieve it.
         *      if (fee == 0 && transferFeeRate != 0) {
         *          return _value;
         *      }
         *      return fee;
         */
    }

    /**
     * @notice The value that you would need to send so that the recipient receives
     * a specified value.
     */
    function transferPlusFee(uint value)
        external
        view
        returns (uint)
    {
        return safeAdd(value, transferFeeIncurred(value));
    }

    /**
     * @notice The quantity to send in order that the sender spends a certain value of tokens.
     */
    function priceToSpend(uint value)
        public
        view
        returns (uint)
    {
        return safeDiv_dec(value, safeAdd(UNIT, transferFeeRate));
    }

    /**
     * @notice Collected fees sit here until they are distributed.
     * @dev The balance of the nomin contract itself is the fee pool.
     */
    function feePool()
        external
        view
        returns (uint)
    {
        return state.balanceOf(address(this));
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice ERC20 friendly transfer function.
     */
    function _transfer_byProxy(address sender, address to, uint value)
        internal
        returns (bool)
    {
        require(to != address(0));

        // The fee is deducted from the sender's balance, in addition to
        // the transferred quantity.
        uint fee = transferFeeIncurred(value);
        uint totalCharge = safeAdd(value, fee);

        // Insufficient balance will be handled by the safe subtraction.
        state.setBalanceOf(sender, safeSub(state.balanceOf(sender), totalCharge));
        state.setBalanceOf(to, safeAdd(state.balanceOf(to), value));
        state.setBalanceOf(address(this), safeAdd(state.balanceOf(address(this)), fee));

        emitTransfer(sender, to, value);
        emitTransfer(sender, address(this), fee);

        return true;
    }

    /**
     * @notice ERC20 friendly transferFrom function.
     */
    function _transferFrom_byProxy(address sender, address from, address to, uint value)
        internal
        returns (bool)
    {
        require(to != address(0));

        // The fee is deducted from the sender's balance, in addition to
        // the transferred quantity.
        uint fee = transferFeeIncurred(value);
        uint totalCharge = safeAdd(value, fee);

        // Insufficient balance will be handled by the safe subtraction.
        state.setBalanceOf(from, safeSub(state.balanceOf(from), totalCharge));
        state.setAllowance(from, sender, safeSub(state.allowance(from, sender), totalCharge));
        state.setBalanceOf(to, safeAdd(state.balanceOf(to), value));
        state.setBalanceOf(address(this), safeAdd(state.balanceOf(address(this)), fee));

        emitTransfer(from, to, value);
        emitTransfer(from, address(this), fee);

        return true;
    }

    /**
     * @notice ERC20 friendly approve function.
     */
    function approve(address spender, uint value)
        external
        optionalProxy
        returns (bool)
    {
        address sender = messageSender;

        state.setAllowance(sender, spender, value);
        emitApproval(sender, spender, value);

        return true;
    }

    /**
     * @notice Withdraw tokens from the fee pool into a given account.
     * @dev Only the fee authority may call this.
     */
    function withdrawFees(address account, uint value)
        external
        onlyFeeAuthority
        returns (bool)
    {
        require(account != address(0));

        // 0-value withdrawals do nothing.
        if (value == 0) {
            return false;
        }

        // Safe subtraction ensures an exception is thrown if the balance is insufficient.
        state.setBalanceOf(address(this), safeSub(state.balanceOf(address(this)), value));
        state.setBalanceOf(account, safeAdd(state.balanceOf(account), value));

        emitFeesWithdrawn(account, value);
        emitTransfer(address(this), account, value);

        return true;
    }

    /**
     * @notice Donate tokens from the sender's balance into the fee pool.
     */
    function donateToFeePool(uint n)
        external
        optionalProxy
        returns (bool)
    {
        address sender = messageSender;
        /* Empty donations are disallowed. */
        uint balance = state.balanceOf(sender);
        require(balance != 0);

        /* safeSub ensures the donor has sufficient balance. */
        state.setBalanceOf(sender, safeSub(balance, n));
        state.setBalanceOf(address(this), safeAdd(state.balanceOf(address(this)), n));

        emitFeesDonated(sender, n);
        emitTransfer(sender, address(this), n);

        return true;
    }


    /* ========== MODIFIERS ========== */

    modifier onlyFeeAuthority
    {
        require(msg.sender == feeAuthority);
        _;
    }


    /* ========== EVENTS ========== */

    event Transfer(address indexed from, address indexed to, uint value);
    bytes32 constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");
    function emitTransfer(address from, address to, uint value) internal {
        proxy._emit(abi.encode(value), 3, TRANSFER_SIG, bytes32(from), bytes32(to), 0);
    }

    event Approval(address indexed owner, address indexed spender, uint value);
    bytes32 constant APPROVAL_SIG = keccak256("Approval(address,address,uint256)");
    function emitApproval(address owner, address spender, uint value) internal {
        proxy._emit(abi.encode(value), 3, APPROVAL_SIG, bytes32(owner), bytes32(spender), 0);
    }

    event TransferFeeRateUpdated(uint newFeeRate);
    bytes32 constant TRANSFERFEERATEUPDATED_SIG = keccak256("TransferFeeRateUpdated(uint256)");
    function emitTransferFeeRateUpdated(uint newFeeRate) internal {
        proxy._emit(abi.encode(newFeeRate), 1, TRANSFERFEERATEUPDATED_SIG, 0, 0, 0);
    }

    event FeeAuthorityUpdated(address newFeeAuthority);
    bytes32 constant FEEAUTHORITYUPDATED_SIG = keccak256("FeeAuthorityUpdated(address)");
    function emitFeeAuthorityUpdated(address newFeeAuthority) internal {
        proxy._emit(abi.encode(newFeeAuthority), 1, FEEAUTHORITYUPDATED_SIG, 0, 0, 0);
    } 

    event StateUpdated(address newState);
    bytes32 constant STATEUPDATED_SIG = keccak256("StateUpdated(address)");
    function emitStateUpdated(address newState) internal {
        proxy._emit(abi.encode(newState), 1, STATEUPDATED_SIG, 0, 0, 0);
    }

    event FeesWithdrawn(address indexed account, uint value);
    bytes32 constant FEESWITHDRAWN_SIG = keccak256("FeesWithdrawn(address,uint256)");
    function emitFeesWithdrawn(address account, uint value) internal {
        proxy._emit(abi.encode(value), 2, FEESWITHDRAWN_SIG, bytes32(account), 0, 0);
    }

    event FeesDonated(address indexed donor, uint value);
    bytes32 constant FEESDONATED_SIG = keccak256("FeesDonated(address,uint256)");
    function emitFeesDonated(address donor, uint value) internal {
        proxy._emit(abi.encode(value), 2, FEESDONATED_SIG, bytes32(donor), 0, 0);
    }
}
