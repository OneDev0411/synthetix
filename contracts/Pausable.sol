/*
-----------------------------------------------------------------
FILE INFORMATION
-----------------------------------------------------------------

file:       Pausable.sol
version:    1.0
author:     Kevin Brown

date:       2018-05-22

checked:    
approved:   

-----------------------------------------------------------------
MODULE DESCRIPTION
-----------------------------------------------------------------

This contract allows an inheriting contract to be marked as
paused. It also defines a modifier which can be used by the
inheriting contract to prevent actions while paused.

-----------------------------------------------------------------
*/

pragma solidity 0.4.24;


import "contracts/Owned.sol";


/**
 * @title A contract that can be paused by its owner
 */
contract Pausable is Owned {
	
	uint public lastPauseTime;
	bool public paused;

	/**
	 * @dev Constructor
	 * @param _owner The account which controls this contract.
	 */
	constructor(address _owner)
	    Owned(_owner)
	    public
	{
		paused = false;
        lastPauseTime = 0;
	}

	/**
	 * @notice Change the paused state of the contract
	 * @dev Only the contract owner may call this.
	 */
	function setPaused(bool _paused)
		external
		onlyOwner
	{
        // Ensure we're actually changing the state before we do anything
        require(_paused != paused);

        // Set our paused state.
		paused = _paused;
        
        // If applicable, set the last pause time.
        if (paused) {
            lastPauseTime = now;
        }

        // Let everyone know that our pause state has changed.
		emit PauseChanged(paused);
	}

	event PauseChanged(bool isPaused);

    modifier notPaused {
        require(!paused);
        _;
    }
}
