const Web3 = require('web3');
const fs = require('fs');
const path = require('path');
const solc = require('solc');
const chalk = require('chalk');
const web3 = new Web3();
const eth = web3.eth;
web3.setProvider(new web3.providers.HttpProvider('http://localhost:8545'));

var accountAdd = web3.personal.newAccount("1");
web3.personal.unlockAccount(accountAdd, "1", 1000);
web3.eth.defaultAccount = accountAdd;

async function deploy_contract(abi, bytecode) {
    let gasEstimate = eth.estimateGas({data: bytecode});
    let localContract = eth.contract(JSON.parse(abi));

    return new Promise (function(resolve, reject) {
    localContract.new({
      from:accountAdd,
      data:bytecode,
      gas:gasEstimate}, function(err, contract){
       if(!err) {
          // NOTE: The callback will fire twice!
          // Once the contract has the transactionHash property set and once its deployed on an address.
           // e.g. check tx hash on the first call (transaction send)
          if(!contract.address) {
          //console.log(contract.transactionHash) // The hash of the transaction, which deploys the contract
         
          // check address on the second call (contract deployed)
          } else {
              //newContract = myContract;
              //contractDeployed = true;
              // setting the global instance to this contract
              resolve(contract);
          }
           // Note that the returned "myContractReturned" === "myContract",
          // so the returned "myContractReturned" object will also get the address set.
       }
     });
    });
}

async function check_tx_mined(tx_hash) {
    let txs = eth.getBlock("latest").transactions;
    return new Promise(function(resolve, reject) {
        while (!txs.includes(tx_hash)) {
            txs = eth.getBlock("latest").transactions;
        }
        resolve("true");
    });
}

async function transactional_method(contract, methodName, args) {
    var tx_hash = await new Promise(function(resolve, reject) {
        contract[methodName]['sendTransaction'](...args, function(err, result) {
            resolve(result);
        });
    });

    let isMined = await check_tx_mined(tx_hash);

    return new Promise(function(resolve, reject) {
        resolve(isMined);
    });
}

function call_method_string(contract, methodName, args) {
    return contract[methodName]['call'](...args);
}

function call_method_int(contract, methodName, args) {
    return contract[methodName]['call'](...args).toNumber();
}

function assertEqual(result_dict, expected, actual) {
    let result = expected === actual;
    result_dict['result'] = result && result_dict['result'];

    // do I want to keep updating the msg
    if (result) {
        result_dict['msg'] = "has Passed";
    } else {
        result_dict['msg'] = "has Failed";
    }

    return result_dict
}

function process_test_result(res, test_name) {
    if (res['result'])
    {
        console.log(chalk.green(test_name + " " + res['msg']));
    } else {
        console.log(chalk.red(test_name + " " +  res['msg']));
    }
}
async function testInc_by3(t_contract) { 
   let assertResult012 = {result: true, msg:""} 
   console.log(chalk.yellow("Running testInc_by3 test")) 
   
   //let c = Counter();
   await transactional_method(t_contract, 'increment', [])
   await transactional_method(t_contract, 'increment', [])
   let v = call_method_int(t_contract, 'getValue', []);
   assertEqual(assertResult012, 2, v)
   assertEqual(assertResult012, 3, v)
   process_test_result(assertResult012, "testInc_by3")
}

async function run_tests(pathToContract, nameOfContract) {
    let source = fs.readFileSync(pathToContract, 'utf8'); 
    let compiledContract = solc.compile(source, 1); 
    let abi = compiledContract.contracts[':_Interface' + nameOfContract].interface; 
    let bytecode = "0x" + compiledContract.contracts[':' + nameOfContract].bytecode; 
    let depContract_0 = await deploy_contract(abi, bytecode); 
    await testInc_by3(depContract_0) 
}

function  main(pathToContract, nameOfContract) {
    run_tests(pathToContract, nameOfContract)
} 

main('main.sol', 'Counter');