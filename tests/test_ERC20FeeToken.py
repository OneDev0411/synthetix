import unittest

from utils.deployutils import W3, compile_contracts, attempt_deploy, mine_tx, UNIT, MASTER, ETHER
from utils.testutils import assertTransactionReverts, assertCallReverts

ERC20FeeToken_SOURCE = "contracts/ERC20FeeToken.sol"

def setUpModule():
    print("Testing ERC20FeeToken...")

def tearDownModule():
    print()

class TestERC20FeeToken(unittest.TestCase):
    """
    Test the basic ERC20 Fee Token contract
    TODO: Add more edge case tests. Comment more. Still in progress.
    """
    @classmethod
    def setUpClass(cls):
        compiled = compile_contracts([ERC20FeeToken_SOURCE])
        cls.erc20feetoken, cls.construction_txr = attempt_deploy(compiled, "ERC20FeeToken", MASTER, 
                                                                 ["Test Fee Token", "TSTFE", 1000 * UNIT, 
                                                                  MASTER, UNIT//20, MASTER, MASTER])
        cls.owner = lambda self: cls.erc20feetoken.functions.owner()
        cls.totalSupply = lambda self: cls.erc20feetoken.functions.totalSupply()
        cls.name = lambda self: cls.erc20feetoken.functions.name()
        cls.symbol = lambda self: cls.erc20feetoken.functions.symbol()
        cls.balanceOf = lambda self, account: self.erc20feetoken.functions.balanceOf(account)
        cls.allowance = lambda self, account, spender: self.erc20feetoken.functions.allowance(account, spender)
        cls.transferFeeRate = lambda self: cls.erc20feetoken.functions.transferFeeRate()
        cls.maxTransferFeeRate = lambda self: cls.erc20feetoken.functions.maxTransferFeeRate()
        cls.feePool = lambda self: cls.erc20feetoken.functions.feePool()
        cls.feeAuthority = lambda self: cls.erc20feetoken.functions.feeAuthority()

        cls.setTransferFeeRate = lambda self, new_fee_rate: cls.erc20feetoken.functions.setTransferFeeRate(new_fee_rate)
        cls.transferFeeIncurred = lambda self, value: cls.erc20feetoken.functions.transferFeeIncurred(value)
        cls.transferPlusFee = lambda self, value: cls.erc20feetoken.functions.transferPlusFee(value)

        cls.transfer = lambda self, to, value: cls.erc20feetoken.functions.transfer(to, value)
        cls.approve = lambda self, spender, value: cls.erc20feetoken.functions.approve(spender, value)
        cls.transferFrom = lambda self, fromAccount, to, value: cls.erc20feetoken.functions.transferFrom(fromAccount, to, value)

        cls.withdrawFee = lambda self, account, value: cls.erc20feetoken.functions.withdrawFee(account, value)

    def test_constructor(self):
        self.assertEqual(self.name().call(), "Test Fee Token")
        self.assertEqual(self.symbol().call(), "TSTFE")
        self.assertEqual(self.totalSupply().call(), 1000 * UNIT)
        self.assertEqual(self.balanceOf(MASTER).call(), 1000 * UNIT)
        self.assertEqual(self.transferFeeRate().call(), UNIT//20)
        self.assertEqual(self.feeAuthority().call(), MASTER)

    def test_getSetTransferFeeRate(self):
        pre_transfer_fee_rate = self.transferFeeRate().call()
        new_transfer_fee_rate = pre_transfer_fee_rate + UNIT//20
        owner = self.owner().call()
        fake_owner = W3.eth.accounts[1]

        # Only the owner is able to set the Transfer Fee Rate
        assertTransactionReverts(self, self.setTransferFeeRate(new_transfer_fee_rate), fake_owner)

        mine_tx(self.setTransferFeeRate(new_transfer_fee_rate).transact({'from': owner}))

        self.assertEqual(self.transferFeeRate().call(), new_transfer_fee_rate)

    def test_transferFeeIncurred(self):
        value = 10 * UNIT
        fee = value * self.transferFeeRate().call() / UNIT
        self.assertEqual(self.transferFeeIncurred(value).call(), fee)

    def test_transferPlusFee(self):
        value = 10 * UNIT
        fee = value * self.transferFeeRate().call() / UNIT
        total = value + fee
        self.assertEqual(self.transferPlusFee(value).call(), total)

    def test_transfer(self):
        sender = MASTER
        sender_balance = self.balanceOf(sender).call()

        receiver = W3.eth.accounts[1]
        receiver_balance = self.balanceOf(receiver).call()

        transfer_amount = 1 * UNIT
        fee = self.transferFeeIncurred(transfer_amount).call()
        total_amount = self.transferPlusFee(transfer_amount).call()
        total_supply = self.totalSupply().call()
        fee_pool = self.feePool().call()

        mine_tx(self.transfer(receiver, transfer_amount).transact({'from': sender}))

        self.assertEquals(self.balanceOf(receiver).call(), receiver_balance + transfer_amount)
        self.assertEquals(self.balanceOf(sender).call(), sender_balance - total_amount)
        self.assertEquals(self.totalSupply().call(), total_supply)
        self.assertEquals(self.feePool().call(), fee_pool + fee)

    def test_fail_transfer(self):
        sender = W3.eth.accounts[2]
        sender_balance = self.balanceOf(sender).call()

        receiver = MASTER
        receiver_balance = self.balanceOf(receiver).call()

        transfer_amount = 1 * UNIT
        fee = self.transferFeeIncurred(transfer_amount).call()
        total_amount = self.transferPlusFee(transfer_amount).call()
        total_supply = self.totalSupply().call()
        fee_pool = self.feePool().call()

        assertTransactionReverts(self, self.transfer(receiver, transfer_amount), sender)

        self.assertEquals(self.balanceOf(sender).call(), sender_balance)
        self.assertEquals(self.balanceOf(receiver).call(), receiver_balance)
        self.assertEquals(self.totalSupply().call(), total_supply)
        self.assertEquals(self.feePool().call(), fee_pool)

    def test_approve(self):
        approver = MASTER
        spender = W3.eth.accounts[1]
        amount = 1 * UNIT

        mine_tx(self.approve(W3.eth.accounts[1], 1 * UNIT).transact({'from': approver}))

        self.assertEqual(self.allowance(approver, W3.eth.accounts[1]).call(), 1 * UNIT)

    def test_transferFrom(self):
        approver = MASTER
        spender = W3.eth.accounts[5]
        receiver = W3.eth.accounts[6]

        approver_balance = self.balanceOf(approver).call()
        spender_balance = self.balanceOf(spender).call()
        receiver_balance = self.balanceOf(receiver).call()

        transfer_amount = 1 * UNIT
        fee = self.transferFeeIncurred(transfer_amount).call()
        total_amount = self.transferPlusFee(transfer_amount).call()
        total_supply = self.totalSupply().call()
        fee_pool = self.feePool().call()

        #Approve total amount inclusive of fee
        mine_tx(self.approve(spender, total_amount).transact({'from': approver}))

        self.assertEqual(self.allowance(approver, spender).call(), total_amount)

        mine_tx(self.transferFrom(approver, receiver, transfer_amount).transact({'from': spender}))

        self.assertEqual(self.balanceOf(approver).call(), approver_balance - total_amount)
        self.assertEqual(self.balanceOf(spender).call(), spender_balance)
        self.assertEqual(self.balanceOf(receiver).call(), receiver_balance + transfer_amount)
        self.assertEqual(self.totalSupply().call(), total_supply)
        self.assertEquals(self.feePool().call(), fee_pool + fee)


    def test_transferFrom_invalid(self):
        approver = W3.eth.accounts[4]
        spender = W3.eth.accounts[5]
        receiver = W3.eth.accounts[6]

        approver_balance = self.balanceOf(approver).call()
        spender_balance = self.balanceOf(spender).call()
        receiver_balance = self.balanceOf(receiver).call()

        transfer_amount = 1 * UNIT
        fee = self.transferFeeIncurred(transfer_amount).call()
        total_amount = self.transferPlusFee(transfer_amount).call()
        total_supply = self.totalSupply().call()
        fee_pool = self.feePool().call()

        mine_tx(self.approve(spender, transfer_amount).transact({'from': approver}))

        assertTransactionReverts(self, self.transferFrom(approver, receiver, transfer_amount), spender)

        self.assertEqual(self.balanceOf(approver).call(), approver_balance)
        self.assertEqual(self.balanceOf(spender).call(), spender_balance)
        self.assertEqual(self.balanceOf(receiver).call(), receiver_balance)
        self.assertEqual(self.totalSupply().call(), total_supply)
        self.assertEquals(self.feePool().call(), fee_pool)

    def test_withdrawFee(self):
        fee_authority = MASTER
        receiver = W3.eth.accounts[1]
        fee_receiver = W3.eth.accounts[2]
        not_fee_authority = W3.eth.accounts[3]

        fee_authority_balance = self.balanceOf(fee_authority).call()
        receiver_balance = self.balanceOf(receiver).call()
        fee_receiver_balance = self.balanceOf(fee_receiver).call()

        transfer_amount = 500 * UNIT
        fee = self.transferFeeIncurred(transfer_amount).call()
        total_amount = self.transferPlusFee(transfer_amount).call()
        total_supply = self.totalSupply().call()
        fee_pool = self.feePool().call()

        mine_tx(self.transfer(receiver, transfer_amount).transact({'from': fee_authority}))

        self.assertEquals(self.balanceOf(receiver).call(), receiver_balance + transfer_amount)
        self.assertEquals(self.balanceOf(fee_authority).call(), fee_authority_balance - total_amount)
        self.assertEquals(self.totalSupply().call(), total_supply)
        self.assertEquals(self.feePool().call(), fee_pool + fee)

        fee_pool = self.feePool().call()

        # Only the Fee Authority can withdraw the Fees
        assertTransactionReverts(self, self.withdrawFee(not_fee_authority, fee_pool), not_fee_authority)

        mine_tx(self.withdrawFee(fee_receiver, fee_pool).transact({'from': fee_authority}))

        self.assertEquals(self.feePool().call(), 0)
        self.assertEquals(self.balanceOf(fee_receiver).call(), fee_receiver_balance + fee_pool)
        self.assertEqual(self.totalSupply().call(), total_supply)

if __name__ == '__main__':
    unittest.main()