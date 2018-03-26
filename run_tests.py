import sys
import os
import subprocess
import time
from unittest import TestSuite, TestLoader, TextTestRunner
from utils.generalutils import load_test_settings, ganache_error_message

from tests import *

if __name__ == '__main__':
    num_agents = "120"
    eth_per_agent = "1000000000000"

    print("Launching ganache...", end="")
    DEVNULL = open(os.devnull, 'wb')
    command = ["ganache-cli", "-a", num_agents, "-e", eth_per_agent]
    try:
        process = subprocess.Popen(command, stdout=DEVNULL, stderr=subprocess.STDOUT)
    except Exception as e:
        raise Exception(ganache_error_message)
    # Wait for ganache to initialise properly.
    time.sleep(5)
    print("Done.")

    test_settings = load_test_settings()

    test_suite = TestSuite()
    loader = TestLoader()
    for item in test_settings:
        if test_settings[item]:
            test_suite.addTests(loader.loadTestsFromModule(getattr(tests, item)))

    print("Running test suite...\n")
    result = TextTestRunner(verbosity=2).run(test_suite)
    process.terminate()
    print("\nTesting complete.")

    sys.exit(0 if result.wasSuccessful() else 1)
