'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const Web3 = require('web3');

const { loadCompiledFiles, getLatestSolTimestamp } = require('../../publish/src/solidity');

const deployCmd = require('../../publish/src/commands/deploy');
const { buildPath } = deployCmd.DEFAULTS;
const commands = {
	build: require('../../publish/src/commands/build').build,
	deploy: deployCmd.deploy,
	replaceSynths: require('../../publish/src/commands/replace-synths').replaceSynths,
	purgeSynths: require('../../publish/src/commands/purge-synths').purgeSynths,
	removeSynths: require('../../publish/src/commands/remove-synths').removeSynths,
};

const {
	SYNTHS_FILENAME,
	CONFIG_FILENAME,
	CONTRACTS_FOLDER,
} = require('../../publish/src/constants');

const snx = require('../..');
const { toBytes32 } = snx;

// load accounts used by local ganache in keys.json
const users = Object.entries(
	JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', 'keys.json'))).private_keys
).map(([pub, pri]) => ({
	public: pub,
	private: `0x${pri}`,
}));

describe('publish scripts', function() {
	this.timeout(5e3);
	const deploymentPath = path.join(__dirname, '..', '..', 'publish', 'deployed', 'local');

	// track these files to revert them later on
	const synthsJSONPath = path.join(deploymentPath, SYNTHS_FILENAME);
	const synthsJSON = fs.readFileSync(synthsJSONPath);
	const configJSONPath = path.join(deploymentPath, CONFIG_FILENAME);
	const configJSON = fs.readFileSync(configJSONPath);
	const logfilePath = path.join(__dirname, 'test.log');
	const network = 'local';
	let gasLimit;
	let gasPrice;
	let accounts;
	let SNX;
	let sUSD;
	let sBTC;
	let web3;

	const resetConfigAndSynthFiles = () => {
		// restore the synths and config files for this env (cause removal updated it)
		fs.writeFileSync(synthsJSONPath, synthsJSON);
		fs.writeFileSync(configJSONPath, configJSON);
	};

	// Note: as deployments take quite a bit of time, we use before here which
	// runs once before all the subsequent tests. This means we need to be careful
	// of anything bleeding over between tests - such as config, synth and deployment JSON files
	before(async function() {
		fs.writeFileSync(logfilePath, ''); // reset log file
		console.log = (...input) => fs.appendFileSync(logfilePath, input.join(' ') + '\n');
		accounts = {
			deployer: users[0],
			first: users[1],
			second: users[2],
		};

		// get last modified sol file
		const latestSolTimestamp = getLatestSolTimestamp(CONTRACTS_FOLDER);

		// get last build
		const { earliestCompiledTimestamp } = loadCompiledFiles({ buildPath });

		if (latestSolTimestamp > earliestCompiledTimestamp) {
			console.log('Found source file modified after build. Rebuilding...');
			this.timeout(60000);
			await commands.build();
		} else {
			console.log('Skipping build as everything up to date');
		}

		gasLimit = 5000000;
		[SNX, sUSD, sBTC] = ['SNX', 'sUSD', 'sBTC'].map(toBytes32);
		web3 = new Web3(new Web3.providers.HttpProvider('http://127.0.0.1:8545'));
		web3.eth.accounts.wallet.add(accounts.deployer.private);
		gasPrice = web3.utils.toWei('5', 'gwei');
	});

	after(resetConfigAndSynthFiles);

	describe('integrated actions test', () => {
		describe('when deployed', () => {
			let sources;
			let targets;
			let synths;
			let Synthetix;
			let timestamp;
			let sUSDContract;
			let sBTCContract;
			let FeePool;
			before(async function() {
				this.timeout(60000);

				await commands.deploy({
					network,
					deploymentPath,
					yes: true,
					privateKey: accounts.deployer.private,
				});

				sources = snx.getSource({ network });
				targets = snx.getTarget({ network });
				synths = snx.getSynths({ network }).filter(({ name }) => name !== 'sUSD' && name !== 'XDR');

				Synthetix = new web3.eth.Contract(
					sources['Synthetix'].abi,
					targets['ProxySynthetix'].address
				);
				FeePool = new web3.eth.Contract(sources['FeePool'].abi, targets['ProxyFeePool'].address);
				sUSDContract = new web3.eth.Contract(sources['Synth'].abi, targets['ProxysUSD'].address);
				sBTCContract = new web3.eth.Contract(sources['Synth'].abi, targets['ProxysBTC'].address);
				timestamp = (await web3.eth.getBlock('latest')).timestamp;
			});

			describe('when ExchangeRates has prices SNX $0.30 and all synths $1', () => {
				before(async () => {
					// make sure exchange rates has a price
					const ExchangeRates = new web3.eth.Contract(
						sources['ExchangeRates'].abi,
						targets['ExchangeRates'].address
					);
					// update rates
					await ExchangeRates.methods
						.updateRates(
							[SNX].concat(synths.map(({ name }) => toBytes32(name))),
							[web3.utils.toWei('0.3')].concat(
								synths.map(({ name, inverted }) => {
									if (name === 'iETH') {
										// ensure iETH is frozen at the lower limit, by setting the incoming rate for sTRX
										// above the upper limit
										return web3.utils.toWei(Math.round(inverted.upperLimit * 2).toString());
									} else if (name === 'iBTC') {
										// ensure iBTC is frozen at the upper limit, by setting the incoming rate for sTRX
										// below the lower limit
										return web3.utils.toWei(Math.round(inverted.lowerLimit * 0.75).toString());
									} else if (name === 'iBNB') {
										// ensure iBNB is not frozen
										return web3.utils.toWei(inverted.entryPoint.toString());
									} else if (name === 'iMKR') {
										// ensure iMKR is frozen
										return web3.utils.toWei(Math.round(inverted.upperLimit * 2).toString());
									} else if (name === 'iCEX') {
										// ensure iCEX is frozen at lower limit
										return web3.utils.toWei(Math.round(inverted.upperLimit * 2).toString());
									} else {
										return web3.utils.toWei('1');
									}
								})
							),
							timestamp
						)
						.send({
							from: accounts.deployer.public,
							gas: gasLimit,
							gasPrice,
						});
				});

				describe('when transferring 100k SNX to user1', () => {
					before(async () => {
						// transfer SNX to first account
						await Synthetix.methods
							.transfer(accounts.first.public, web3.utils.toWei('100000'))
							.send({
								from: accounts.deployer.public,
								gas: gasLimit,
								gasPrice,
							});
					});
					describe('continue on integration test', () => {
						describe('when user1 issues all possible sUSD', () => {
							before(async () => {
								await Synthetix.methods.issueMaxSynths(sUSD).send({
									from: accounts.first.public,
									gas: gasLimit,
									gasPrice,
								});
							});
							it('then the sUSD balanced must be 100k * 0.3 * 0.2 (default SynthetixState.issuanceRatio) = 6000', async () => {
								const balance = await sUSDContract.methods.balanceOf(accounts.first.public).call();
								assert.strictEqual(web3.utils.fromWei(balance), '6000', 'Balance should match');
							});
							describe('when user1 exchange 1000 sUSD for sBTC', () => {
								let sBTCBalanceAfterExchange;
								before(async () => {
									await Synthetix.methods.exchange(sUSD, web3.utils.toWei('1000'), sBTC).send({
										from: accounts.first.public,
										gas: gasLimit,
										gasPrice,
									});
								});
								it('then their sUSD balance is 5000', async () => {
									const balance = await sUSDContract.methods
										.balanceOf(accounts.first.public)
										.call();
									assert.strictEqual(web3.utils.fromWei(balance), '5000', 'Balance should match');
								});
								it('and their sBTC balance is 1000 - the fee', async () => {
									sBTCBalanceAfterExchange = await sBTCContract.methods
										.balanceOf(accounts.first.public)
										.call();
									const expected = await FeePool.methods
										.amountReceivedFromExchange(web3.utils.toWei('1000'))
										.call();
									assert.strictEqual(
										web3.utils.fromWei(sBTCBalanceAfterExchange),
										web3.utils.fromWei(expected),
										'Balance should match'
									);
								});
								describe('when user1 burns 10 sUSD', () => {
									before(async () => {
										// burn
										await Synthetix.methods.burnSynths(sUSD, web3.utils.toWei('10')).send({
											from: accounts.first.public,
											gas: gasLimit,
											gasPrice,
										});
									});
									it('then their sUSD balance is 4990', async () => {
										const balance = await sUSDContract.methods
											.balanceOf(accounts.first.public)
											.call();
										assert.strictEqual(web3.utils.fromWei(balance), '4990', 'Balance should match');
									});

									describe('when deployer replaces sBTC with PurgeableSynth', () => {
										before(async () => {
											await commands.replaceSynths({
												network,
												deploymentPath,
												yes: true,
												privateKey: accounts.deployer.private,
												subclass: 'PurgeableSynth',
												synthsToReplace: ['sBTC'],
											});
										});
										describe('and deployer invokes purge', () => {
											before(async () => {
												await commands.purgeSynths({
													network,
													deploymentPath,
													yes: true,
													privateKey: accounts.deployer.private,
													addresses: [accounts.first.public],
													synthsToPurge: ['sBTC'],
												});
											});
											it('then their sUSD balance is 4990 + sBTCBalanceAfterExchange', async () => {
												const balance = await sUSDContract.methods
													.balanceOf(accounts.first.public)
													.call();
												assert.strictEqual(
													web3.utils.fromWei(balance),
													(4990 + +web3.utils.fromWei(sBTCBalanceAfterExchange)).toString(),
													'Balance should match'
												);
											});
											it('and their sBTC balance is 0', async () => {
												const balance = await sBTCContract.methods
													.balanceOf(accounts.first.public)
													.call();
												assert.strictEqual(
													web3.utils.fromWei(balance),
													'0',
													'Balance should match'
												);
											});
											describe('and deployer invokes remove of sBTC', () => {
												before(async () => {
													await commands.removeSynths({
														network,
														deploymentPath,
														yes: true,
														privateKey: accounts.deployer.private,
														synthsToRemove: ['sBTC'],
													});
												});

												describe('when user tries to exchange into sBTC', () => {
													it('then it fails', done => {
														Synthetix.methods
															.exchange(sUSD, web3.utils.toWei('1000'), sBTC)
															.send({
																from: accounts.first.public,
																gas: gasLimit,
																gasPrice,
															})
															.then(() => done('Should not have complete'))
															.catch(() => done());
													});
												});
											});
										});
									});
								});
							});
						});
					});

					describe('handle updates to inverted rates', () => {
						describe('when a new inverted synth iABC is added to the list', () => {
							describe('and the inverted synth iMKR has its parameters shifted', () => {
								describe('and the inverted synth iCEX has its parameters shifted as well', () => {
									before(async () => {
										// read current config file version (if something has been removed,
										// we don't want to include it here)
										const currentSynthsFile = JSON.parse(fs.readFileSync(synthsJSONPath));

										// add new iABC synth
										currentSynthsFile.push({
											name: 'iABC',
											asset: 'ABC',
											category: 'crypto',
											sign: '',
											desc: 'Inverted Alphabet',
											subclass: 'PurgeableSynth',
											inverted: {
												entryPoint: 1,
												upperLimit: 1.5,
												lowerLimit: 0.5,
											},
										});

										// mutate parameters of iMKR
										// Note: this is brittle and will *break* if iMKR or iCEX are removed from the
										// synths for deployment. This needs to be improved in the near future - JJ
										currentSynthsFile.find(({ name }) => name === 'iMKR').inverted = {
											entryPoint: 100,
											upperLimit: 150,
											lowerLimit: 50,
										};

										// mutate parameters of iCEX
										currentSynthsFile.find(({ name }) => name === 'iCEX').inverted = {
											entryPoint: 1,
											upperLimit: 1.5,
											lowerLimit: 0.5,
										};

										fs.writeFileSync(synthsJSONPath, JSON.stringify(currentSynthsFile));
									});

									describe('when a user has issued into iCEX', () => {
										before(async () => {
											await Synthetix.methods.issueMaxSynths(toBytes32('iCEX')).send({
												from: accounts.first.public,
												gas: gasLimit,
												gasPrice,
											});
										});

										describe('when ExchangeRates alone is redeployed', () => {
											let ExchangeRates;
											before(async () => {
												// read current config file version (if something has been removed,
												// we don't want to include it here)
												const currentConfigFile = JSON.parse(fs.readFileSync(configJSONPath));
												const configForExrates = Object.keys(currentConfigFile).reduce(
													(memo, cur) => {
														memo[cur] = { deploy: cur === 'ExchangeRates' };
														return memo;
													},
													{}
												);

												fs.writeFileSync(configJSONPath, JSON.stringify(configForExrates));

												await commands.deploy({
													addNewSynths: true,
													network,
													deploymentPath,
													yes: true,
													privateKey: accounts.deployer.private,
												});

												ExchangeRates = new web3.eth.Contract(
													sources['ExchangeRates'].abi,
													snx.getTarget({ network, contract: 'ExchangeRates' }).address
												);
											});

											after(resetConfigAndSynthFiles);

											// Test the properties of an inverted synth
											const testInvertedSynth = async ({
												currencyKey,
												shouldBeFrozen,
												expectedPropNameOfFrozenLimit,
											}) => {
												const {
													entryPoint,
													upperLimit,
													lowerLimit,
													frozen,
												} = await ExchangeRates.methods
													.inversePricing(toBytes32(currencyKey))
													.call();
												const rate = await ExchangeRates.methods
													.rateForCurrency(toBytes32(currencyKey))
													.call();
												const expected = synths.find(({ name }) => name === currencyKey).inverted;
												assert.strictEqual(
													+web3.utils.fromWei(entryPoint),
													expected.entryPoint,
													'Entry points match'
												);
												assert.strictEqual(
													+web3.utils.fromWei(upperLimit),
													expected.upperLimit,
													'Upper limits match'
												);
												assert.strictEqual(
													+web3.utils.fromWei(lowerLimit),
													expected.lowerLimit,
													'Lower limits match'
												);
												assert.strictEqual(frozen, shouldBeFrozen, 'Frozen matches expectation');

												if (expectedPropNameOfFrozenLimit) {
													assert.strictEqual(
														+web3.utils.fromWei(rate),
														expected[expectedPropNameOfFrozenLimit],
														'Frozen correctly at limit'
													);
												}
											};

											it('then the new iABC synth should be added correctly (as it has no previous rate)', async () => {
												const iABC = toBytes32('iABC');
												const {
													entryPoint,
													upperLimit,
													lowerLimit,
													frozen,
												} = await ExchangeRates.methods.inversePricing(iABC).call();
												const rate = await ExchangeRates.methods.rateForCurrency(iABC).call();

												assert.strictEqual(+web3.utils.fromWei(entryPoint), 1, 'Entry point match');
												assert.strictEqual(
													+web3.utils.fromWei(upperLimit),
													1.5,
													'Upper limit match'
												);
												assert.strictEqual(
													+web3.utils.fromWei(lowerLimit),
													0.5,
													'Lower limit match'
												);
												assert.strictEqual(frozen, false, 'Is not frozen');
												assert.strictEqual(
													+web3.utils.fromWei(rate),
													0,
													'No rate for new inverted synth'
												);
											});

											it('and the iMKR synth should be reconfigured correctly (as it has 0 total supply)', async () => {
												const iMKR = toBytes32('iMKR');
												const {
													entryPoint,
													upperLimit,
													lowerLimit,
													frozen,
												} = await ExchangeRates.methods.inversePricing(iMKR).call();
												const rate = await ExchangeRates.methods.rateForCurrency(iMKR).call();

												assert.strictEqual(
													+web3.utils.fromWei(entryPoint),
													100,
													'Entry point match'
												);
												assert.strictEqual(
													+web3.utils.fromWei(upperLimit),
													150,
													'Upper limit match'
												);
												assert.strictEqual(
													+web3.utils.fromWei(lowerLimit),
													50,
													'Lower limit match'
												);
												assert.strictEqual(frozen, false, 'Is not frozen');
												assert.strictEqual(+web3.utils.fromWei(rate), 0, 'No rate for iMKR');
											});

											it('and the iCEX synth should not be inverted at all', async () => {
												const { entryPoint } = await ExchangeRates.methods
													.inversePricing(toBytes32('iCEX'))
													.call();

												assert.strictEqual(
													+web3.utils.fromWei(entryPoint),
													0,
													'iCEX should not be set'
												);
											});

											it('and iETH should be set as frozen at the lower limit', async () => {
												await testInvertedSynth({
													currencyKey: 'iETH',
													shouldBeFrozen: true,
													expectedPropNameOfFrozenLimit: 'lowerLimit',
												});
											});
											it('and iBTC should be set as frozen at the upper limit', async () => {
												await testInvertedSynth({
													currencyKey: 'iBTC',
													shouldBeFrozen: true,
													expectedPropNameOfFrozenLimit: 'upperLimit',
												});
											});
											it('and iBNB should not be frozen', async () => {
												await testInvertedSynth({
													currencyKey: 'iBNB',
													shouldBeFrozen: false,
												});
											});
										});
									});
								});
							});
						});
					});
				});
			});
		});
	});
});
