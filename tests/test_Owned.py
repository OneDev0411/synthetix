import unittest

from utils.deployutils import compile_contracts, attempt_deploy, mine_tx, MASTER, DUMMY
from utils.testutils import assertTransactionReverts

OWNED_SOURCE = "contracts/Owned.sol"


def setUpModule():
    print("Testing Owned...")


def tearDownModule():
    print()


class TestOwned(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiled = compile_contracts([OWNED_SOURCE])
        cls.owned, txr = attempt_deploy(compiled, 'Owned', MASTER, [MASTER])

    def test_owner_is_master(self):
        self.assertEqual(self.owned.functions.owner().call(), MASTER)

    def test_change_owner(self):
        old_owner = self.owned.functions.owner().call()
        new_owner = DUMMY

        mine_tx(self.owned.functions.setOwner(new_owner).transact({'from': MASTER}))
        self.assertEqual(self.owned.functions.owner().call(), new_owner)

        mine_tx(self.owned.functions.setOwner(old_owner).transact({'from': new_owner}))

    def test_change_invalid_owner(self):
        invalid_account = DUMMY
        assertTransactionReverts(self, self.owned.functions.setOwner(invalid_account), invalid_account)


if __name__ == '__main__':
    unittest.main()
