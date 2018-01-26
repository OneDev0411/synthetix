import unittest
from deploy_utils import mine_tx

def assertCallReverts(testcase, function):
    with testcase.assertRaises(ValueError) as error:
        function.call()
    testcase.assertTrue("revert" in error.exception.args[0]['message'])
    testcase.assertEqual(-32000, error.exception.args[0]['code'])

def assertTransactionReverts(testcase, function, caller, gas=5000000):
    with testcase.assertRaises(ValueError) as error:
        mine_tx(function.transact({'from': caller, 'gas': gas}))
    testcase.assertTrue("revert" in error.exception.args[0]['message'])
    testcase.assertEqual(-32000, error.exception.args[0]['code'])
