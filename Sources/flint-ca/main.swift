import Foundation
import Commander
import AST
import ContractAnalysis
import Diagnostic

/// The main function for the compiler.
func main() {
    command (
        Flag("typestate information", flag:"t", description:"Information for typestates"),
        Flag("caller capability analysis", flag:"c", description:"Information for caller capabilites"),
        Flag("gas estimation", flag:"g", description:"gas estimation of contract and functions"),
        Flag("function analysis", flag:"f", description:"run function analysis"),
        Flag("test harness", flag:"u", description:"run in test harness mode"),
        Argument<String> ("source code", description: "source code to verify"),
        Argument<String> ("file name", description: "file name")
    )
    { typeStateDiagram, callerAnalysis, estimateGas, fA, test_run, sourceCode, fileName in
        
        do {
            let a = Analyser(contractFile: fileName,
                             sourceCode: sourceCode,
                             estimateGas: estimateGas,
                             typeStateDiagram: typeStateDiagram,
                             callerCapabilityAnalysis: callerAnalysis,
                             test_run: test_run,
                             function_analysis: fA)
            try a.analyse()
            
        } catch let err {
            print(err)
        }
    }.run() 
}

func main_d() throws {
        let fileName = "/Users/Zubair/Documents/Imperial/Thesis/Code/flint/flint_contracts/demo/counter.flint"
        let inputFiles = [URL(fileURLWithPath: fileName)]
        let sourceCode = try String(contentsOf: inputFiles[0])
    
        do {
             let a = Analyser(contractFile: fileName,
                         sourceCode: sourceCode,
                         estimateGas: true,
                         typeStateDiagram: false,
                         callerCapabilityAnalysis: false,
                         test_run: false,
                         function_analysis: false)
             try a.analyse()
        
        } catch let err {
          print(err)
        }
}

//try main_d()
main()
