import unittest
from utils.deployutils import (
    UNIT, MASTER, DUMMY, 
    compile_contracts, attempt_deploy, mine_tx,
    take_snapshot, restore_snapshot
)
from utils.testutils import HavvenTestCase, ZERO_ADDRESS
from tests.contract_interfaces.token_state_interface import TokenStateInterface


def deploy_state(name, compiled, sender, owner, supply, beneficiary, associated_contract):
    state_contract, construction_tx = attempt_deploy(
        compiled, name, sender, [owner, supply, beneficiary, associated_contract]
    )
    return state_contract


def setUpModule():
    print("Testing TokenState...")


def tearDownModule():
    print()


class TestTokenState(HavvenTestCase):
    def setUp(self):
        self.snapshot = take_snapshot()

    def tearDown(self):
        restore_snapshot(self.snapshot)

    @staticmethod
    def deployContracts():
        sources = ["contracts/TokenState.sol"]
        compiled = compile_contracts(sources, remappings=['""=contracts'])
        tokenstate, _ = attempt_deploy(compiled, 'TokenState', MASTER, [MASTER, DUMMY])
        return tokenstate

    @classmethod
    def setUpClass(cls):
        cls.tokenstate_contract = cls.deployContracts()
        cls.tokenstate = TokenStateInterface(cls.tokenstate_contract)
        cls.owner = MASTER
        cls.associate = DUMMY

    def test_constructor(self):
        self.assertEquals(self.tokenstate.owner(), self.owner)
        self.assertEquals(self.tokenstate.associatedContract(), self.associate)

    def test_setAssociatedContract(self):
        new_token = ZERO_ADDRESS

        # Non-owner can't set the associated contract
        self.assertReverts(self.tokenstate.setAssociatedContract, DUMMY, new_token)

        self.assertEqual(self.tokenstate.balanceOf(DUMMY), 0)
        self.tokenstate.setBalanceOf(self.associate, DUMMY, UNIT)
        self.tokenstate.setAssociatedContract(MASTER, new_token)
        self.assertEqual(self.tokenstate.associatedContract(), new_token)
        self.assertEqual(self.tokenstate.balanceOf(DUMMY), UNIT)

    def test_setAllowance(self):

        self.assertEqual(self.tokenstate.allowance(MASTER, DUMMY), 0)
        self.tokenstate.setAllowance(self.associate, MASTER, DUMMY, UNIT)
        self.assertEqual(self.tokenstate.allowance(MASTER, DUMMY), UNIT)

        # Only the associated contract should be able to set allowances.
        self.assertNotEqual(self.associate, MASTER)
        self.assertReverts(self.tokenstate.setAllowance, MASTER, MASTER, DUMMY, UNIT)


    def test_setBalanceOf(self):
        self.assertEqual(self.tokenstate.balanceOf(MASTER), 0)
        self.tokenstate.setBalanceOf(self.associate, MASTER, UNIT)
        self.assertEqual(self.tokenstate.balanceOf(MASTER), UNIT)

        # Only the associated contract should be able to set allowances.
        self.assertNotEqual(self.associate, MASTER)
        self.assertReverts(self.tokenstate.setBalanceOf, MASTER, MASTER, 2*UNIT)
