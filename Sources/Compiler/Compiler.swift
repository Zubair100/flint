//
//  Compiler.swift
//  flintcPackageDescription
//
//  Created by Franklin Schrans on 12/19/17.
//

import Foundation
import AST
import Diagnostic
import Lexer
import Parser
import ASTPreprocessor
import SemanticAnalyzer
import TypeChecker
import Optimizer
import IRGen
import Verifier


/// Runs the different stages of the compiler.
public struct Compiler {
  public static let defaultASTPasses: [ASTPass] = [
    ASTPreprocessor(),
    EnclosingTypeAssigner(),
    SemanticAnalyzer(),
    TypeChecker(),
    Optimizer(),
    TraitResolver(),
    FunctionCallCompleter(),
    CallGraphGenerator(),
    ConstructorPreProcessor()]

  private static func exitWithFailure() -> Never {
    print("ERROR")
    print("Failed to compile.")
    exit(1)
  }

  private static func tokenizeFiles(inputFiles: [URL], withStandardLibrary: Bool = true) throws -> [Token] {
    let stdlibTokens: [Token]
    if withStandardLibrary {
      stdlibTokens = try StandardLibrary.default.files.flatMap { try Lexer(sourceFile: $0, isFromStdlib: true).lex() }
    } else {
      stdlibTokens = []
    }

    let userTokens = try inputFiles.flatMap { try Lexer(sourceFile: $0).lex() }

    return stdlibTokens + userTokens
  }
    
   private static func tokenizeSourceCode(sourceFile : URL, sourceCode : String) throws -> [Token] {
        let stdlibTokens = try StandardLibrary.default.files.flatMap { try Lexer(sourceFile: $0, isFromStdlib: true).lex() }
        let userTokens = try Lexer(sourceFile: sourceFile, isFromStdlib: false, isForServer: true, sourceCode: sourceCode).lex()
        return stdlibTokens + userTokens
  }
}

// MARK: - Diagnosis
extension Compiler {
  public static func diagnose(config: DiagnoserConfiguration) throws -> [Diagnostic] {
    var diagnoseResult: [Diagnostic] = []
    let tokens = try tokenizeFiles(inputFiles: config.inputFiles)

    // Turn the tokens into an Abstract Syntax Tree (AST).
    let (parserAST, environment, parserDiagnostics) = Parser(tokens: tokens).parse()
    diagnoseResult += parserDiagnostics
    guard let ast = parserAST else {
      return diagnoseResult
    }

    // Run all of the passes.
    let passRunnerOutcome = ASTPassRunner(ast: ast).run(
      passes: config.astPasses,
      in: environment,
      sourceContext: SourceContext(sourceFiles: config.inputFiles))
    diagnoseResult += passRunnerOutcome.diagnostics

    return diagnoseResult
  }
}

// MARK: - Compilation
extension Compiler {
  public static func compile(config: CompilerConfiguration) throws -> CompilationOutcome {
    let tokens = try tokenizeFiles(inputFiles: config.inputFiles, withStandardLibrary: config.loadStdlib)

    // Turn the tokens into an Abstract Syntax Tree (AST).
    let (parserAST, environment, parserDiagnostics) = Parser(tokens: tokens).parse()

    if let failed = try config.diagnostics.checkpoint(parserDiagnostics) {
      if failed {
        exitWithFailure()
      }
      exit(0)
    }

    guard let ast = parserAST else {
      exitWithFailure()
    }

    let sourceContext = SourceContext(sourceFiles: config.inputFiles)

    // Run all of the passes.
    let passRunnerOutcome = ASTPassRunner(ast: ast).run(passes: config.astPasses,
                                                        in: environment,
                                                        sourceContext: sourceContext)
    if let failed = try config.diagnostics.checkpoint(passRunnerOutcome.diagnostics) {
      if failed {
        exitWithFailure()
      }
      exit(0)
    }

    if config.dumpAST {
      print(ASTDumper(topLevelModule: passRunnerOutcome.element).dump())
      exit(0)
    }

    // Run verifier
    if !config.skipVerifier {
      let (verified, errors) = BoogieVerifier(dumpVerifierIR: config.dumpVerifierIR,
                                              printVerificationOutput: config.printVerificationOutput,
                                              skipHolisticCheck: config.skipHolisticCheck,
                                              printHolisticRunStats: config.printHolisticRunStats,
                                              boogieLocation: "boogie/Binaries/Boogie.exe",
                                              symbooglixLocation: "symbooglix/src/SymbooglixDriver/bin/Release/sbx.exe",
                                              maxTransactionDepth: config.maxTransactionDepth,
                                              maxHolisticTimeout: config.maxHolisticTimeout,
                                              monoLocation: "/usr/bin/mono",
                                              topLevelModule: passRunnerOutcome.element,
                                              environment: passRunnerOutcome.environment,
                                              sourceContext: sourceContext,
                                              normaliser: IdentifierNormaliser()).verify()

      _ = try config.diagnostics.checkpoint(errors)
      if verified {
        _ = try config.diagnostics.display()
        print("Contract specification verified!")
      } else {
        print("Contract specification not verified")
        exitWithFailure()
      }
    }

    if config.skipCodeGen {
      exit(0)
    }

    // Run final IRPreprocessor pass
    let irPreprocessOutcome = ASTPassRunner(ast: passRunnerOutcome.element).run(
      passes: (!config.skipVerifier ? [AssertPreprocessor()] : []) + [PreConditionPreprocessor(checkAllFunctions: config.skipVerifier),
              IRPreprocessor()],
      in: environment,
      sourceContext: sourceContext)
    if let failed = try config.diagnostics.checkpoint(irPreprocessOutcome.diagnostics) {
      if failed {
        exitWithFailure()
      }
      exit(0)
    }
    // Generate YUL IR code.
    let irCode = IRCodeGenerator(topLevelModule: irPreprocessOutcome.element,
                                 environment: irPreprocessOutcome.environment)
      .generateCode()

    // Compile the YUL IR code using solc.
    try SolcCompiler(inputSource: irCode,
                     outputDirectory: config.outputDirectory,
                     emitBytecode: config.emitBytecode).compile()

    try config.diagnostics.display()

    print("Produced binary in \(config.outputDirectory.path.bold).")
    return CompilationOutcome(irCode: irCode, astDump: ASTDumper(topLevelModule: ast).dump())
  }
}

// MARK: - TestingFramework Compiler hooks
extension Compiler {
    
    private static func createConstructor(constructor : SpecialDeclaration, enclosingType: String) -> FunctionDeclaration? {
        
        if (!(constructor.signature.specialToken.kind == .init)) {
            return nil
        }
        
        if (constructor.body.count == 0) {
            return nil
        }
        
        var sig = constructor.signature
        sig.modifiers.append(Token(kind: Token.Kind.mutating, sourceLocation : sig.sourceLocation))
        let tok : Token = Token(kind: Token.Kind.func, sourceLocation: sig.sourceLocation)

        let newFunctionSig = FunctionSignatureDeclaration(funcToken: tok, attributes: sig.attributes, modifiers: sig.modifiers, mutates: [], identifier: Identifier(name: "testFrameworkConstructor", sourceLocation: sig.sourceLocation), parameters: sig.parameters,  prePostConditions: [], closeBracketToken: sig.closeBracketToken, resultType: nil)
        
        var newFunc = FunctionDeclaration(signature: newFunctionSig, body: constructor.body, closeBraceToken: constructor.closeBraceToken, scopeContext: constructor.scopeContext)
        
        let parameters = newFunc.signature.parameters.rawTypes
        let name = Mangler.mangleFunctionName(newFunc.identifier.name,
                                              parameterTypes: parameters,
                                              enclosingType: enclosingType)
        newFunc.mangledIdentifier = name

    
        return newFunc
    }
    
    private static func insertConstructorFunc(ast : TopLevelModule) -> TopLevelModule {
        let decWithoutStdlib = ast.declarations[2...]
        
        var newDecs : [TopLevelDeclaration] = []
        newDecs.append(ast.declarations[0])
        newDecs.append(ast.declarations[1])
        
        for m in decWithoutStdlib {
            switch (m) {
            case .contractDeclaration(let cdec):
                newDecs.append(m)
            case .contractBehaviorDeclaration(var cbdec):
                var mems : [ContractBehaviorMember] = []
                for cm in cbdec.members {
                    switch (cm) {
                    case .specialDeclaration(let spdec):
                        if let constructorFunc = createConstructor(constructor: spdec, enclosingType: cbdec.contractIdentifier.name) {
                            let cBeh : ContractBehaviorMember = .functionDeclaration(constructorFunc)
                            mems.append(cBeh)
                            mems.append(.specialDeclaration(spdec))
                        } else {
                            mems.append(cm)
                        }
                    default:
                        mems.append(cm)
                    }
                }
                cbdec.members = mems
                newDecs.append(.contractBehaviorDeclaration(cbdec))
            default:
                newDecs.append(m)
            }
        }
        
        return TopLevelModule(declarations: newDecs)
    }
    
    public static func getAST(config: CompilerTestFrameworkConfiguration) throws -> (TopLevelModule, Environment) {
        
        let tokens = try tokenizeFiles(inputFiles: config.sourceFiles)
        
        let (parserAST, environment, parserDiagnostics) = Parser(tokens: tokens).parse()
        
        if let failed = try config.diagnostics.checkpoint(parserDiagnostics) {
            if failed {
                exitWithFailure()
            }
            exit(0)
        }
        
        guard let ast = parserAST else {
            exitWithFailure()
        }
  
        // Run all of the passes.
        let passRunnerOutcome = ASTPassRunner(ast: ast)
            .run(passes: config.astPasses,
                 in: environment,
                 sourceContext: SourceContext(sourceFiles: config.sourceFiles))
        
        if let failed = try config.diagnostics.checkpoint(passRunnerOutcome.diagnostics) {
            if failed {
                exitWithFailure()
            }
            exit(0)
        }
        
        return (ast, environment)
    }
    
    
    public static func compile_for_test(config : CompilerTestFrameworkConfiguration, in_ast : TopLevelModule) throws {
        
        var ast = in_ast
        
        let p = Parser(ast: ast)
        let environment = p.getEnv()
        
        // Run all of the passes. (Semantic checks)
        let passRunnerOutcome = ASTPassRunner(ast: ast)
            .run(passes: config.astPasses,
                 in: environment,
                 sourceContext: SourceContext(sourceFiles: config.sourceFiles, sourceCodeString: config.sourceCode, isForServer: true))
        
        if let failed = try config.diagnostics.checkpoint(passRunnerOutcome.diagnostics) {
            if failed {
                exitWithFailure()
            }
            exit(0)
        }
        
        ast = insertConstructorFunc(ast: passRunnerOutcome.element)
        
        // Generate YUL IR code.
        let irCode = IRCodeGenerator(topLevelModule: ast, environment: passRunnerOutcome.environment)
            .generateCode()
        
        // Compile the YUL IR code using solc.
        try SolcCompiler(inputSource: irCode, outputDirectory: config.outputDirectory, emitBytecode: false).compile()
        
        // these are warnings from the solc compiler
        try config.diagnostics.display()
        
        let fileName = "main.sol"
        let irFileURL: URL
        irFileURL = config.outputDirectory.appendingPathComponent(fileName)
        do {
            try irCode.write(to: irFileURL, atomically: true, encoding: .utf8)
        } catch {
            exitWithUnableToWriteIRFile(irFileURL: irFileURL)
        }
    }
}

// MARK: - Compiler hook for contract analyser
extension Compiler {
    public static func getAST(config: CompilerContractAnalyserConfiguration) throws -> (TopLevelModule, Environment) {
        
        let tokens = try tokenizeSourceCode(sourceFile: config.sourceFiles[0], sourceCode: config.sourceCode)
        
        let (parserAST, environment, parserDiagnostics) = Parser(tokens: tokens).parse()
        
        if let failed = try config.diagnostics.checkpoint(parserDiagnostics) {
            if failed {
                exitWithFailure()
            }
            exit(0)
        }
        
        guard let ast = parserAST else {
            exitWithFailure()
        }
        
        // Run all of the passes.
        let passRunnerOutcome = ASTPassRunner(ast: ast)
            .run(passes: config.astPasses,
                 in: environment,
                 sourceContext: SourceContext(sourceFiles: config.sourceFiles,
                                              sourceCodeString: config.sourceCode,
                                              isForServer: true))
        if let failed = try config.diagnostics.checkpoint(passRunnerOutcome.diagnostics) {
            if failed {
                exitWithFailure()
            }
            exit(0)
        }
        
        return (parserAST!, environment)
        
    }
    
    public static func genSolFile(config: CompilerContractAnalyserConfiguration, ast: TopLevelModule, env: Environment) throws {
        
        // Run all of the passes.
        let passRunnerOutcome = ASTPassRunner(ast: ast)
            .run(passes: config.astPasses,
                 in: env,
                 sourceContext: SourceContext(sourceFiles: config.sourceFiles,
                                              sourceCodeString: config.sourceCode,
                                              isForServer: true))
        if let failed = try config.diagnostics.checkpoint(passRunnerOutcome.diagnostics) {
            if failed {
                exitWithFailure()
            }
            exit(0)
        }
        
        // Generate YUL IR code.
        let irCode = IRCodeGenerator(topLevelModule: passRunnerOutcome.element, environment: passRunnerOutcome.environment)
            .generateCode()
        
        // Compile the YUL IR code using solc.
        try SolcCompiler(inputSource: irCode, outputDirectory: config.outputDirectory, emitBytecode: false).compile()
        
        // these are warnings from the solc compiler
        try config.diagnostics.display()
        
        let fileName = "main.sol"
        let irFileURL: URL
        irFileURL = config.outputDirectory.appendingPathComponent(fileName)
        do {
            try irCode.write(to: irFileURL, atomically: true, encoding: .utf8)
        } catch {
            exitWithUnableToWriteIRFile(irFileURL: irFileURL)
        }
    }
    
}

// MARK: Compile hook for repl
extension Compiler {
    
    private static func createConstructorRepl(constructor : SpecialDeclaration) -> FunctionDeclaration? {
        
        if (!(constructor.signature.specialToken.kind == .init)) {
            return nil
        }
        
        if (constructor.body.count == 0) {
            return nil
        }
        
        var sig = constructor.signature
        sig.modifiers.append(Token(kind: Token.Kind.mutating, sourceLocation : sig.sourceLocation))
        let tok : Token = Token(kind: Token.Kind.func, sourceLocation: sig.sourceLocation)
        let newFunctionSig = FunctionSignatureDeclaration(funcToken: tok, attributes: sig.attributes, modifiers: sig.modifiers, mutates: [], identifier: Identifier(name: "replConstructor", sourceLocation: sig.sourceLocation), parameters: sig.parameters, prePostConditions: [], closeBracketToken: sig.closeBracketToken, resultType: nil)
        let newFunc = FunctionDeclaration(signature: newFunctionSig, body: constructor.body, closeBraceToken: constructor.closeBraceToken)
        
        return newFunc
    }
    
    private static func insertConstructorFuncRepl(ast : TopLevelModule) -> TopLevelModule {
       
        var newDecs : [TopLevelDeclaration] = []
        
        for m in ast.declarations {
            switch (m) {
            case .contractBehaviorDeclaration(var cbdec):
                var mems : [ContractBehaviorMember] = []
                for cm in cbdec.members {
                    switch (cm) {
                    case .specialDeclaration(let spdec):
                        if let constructorFunc = createConstructorRepl(constructor: spdec) {
                            let cBeh : ContractBehaviorMember = .functionDeclaration(constructorFunc)
                            mems.append(cBeh)
                            mems.append(.specialDeclaration(spdec))
                        } else {
                            mems.append(cm)
                        }
                    default:
                        mems.append(cm)
                    }
                }
                cbdec.members = mems
                newDecs.append(.contractBehaviorDeclaration(cbdec))
            default:
                newDecs.append(m)
            }
        }
        
        return TopLevelModule(declarations: newDecs)
    }
    
    public static func getAST(config: CompilerReplConfiguration) throws -> (TopLevelModule, Environment) {
        
        let tokens = try tokenizeFiles(inputFiles: config.sourceFiles)
     
        let (parserAST, environment, parserDiagnostics) = Parser(tokens: tokens).parse()
        
        if let failed = try config.diagnostics.checkpoint(parserDiagnostics) {
            if failed {
                exitWithFailure()
            }
            exit(0)
        }
        
        
        guard var ast = parserAST else {
            exitWithFailure()
        }
        
        
        ast = insertConstructorFuncRepl(ast: parserAST!)
      
        // Run all of the passes.
        let passRunnerOutcome = ASTPassRunner(ast: ast)
            .run(passes: config.astPasses,
                 in: environment,
                 sourceContext: SourceContext(sourceFiles: config.sourceFiles))
        
        if let failed = try config.diagnostics.checkpoint(passRunnerOutcome.diagnostics) {
            if failed {
                exitWithFailure()
            }
            exit(0)
        }
        
        return (ast, environment)
    }
    
    public static func genSolFile(config: CompilerReplConfiguration, ast: TopLevelModule, env: Environment) throws {
        
        // Run all of the passes.
        let passRunnerOutcome = ASTPassRunner(ast: ast)
            .run(passes: config.astPasses,
                 in: env,
                 sourceContext: SourceContext(sourceFiles: config.sourceFiles))
        
        if let failed = try config.diagnostics.checkpoint(passRunnerOutcome.diagnostics) {
            if failed {
                exitWithFailure()
            }
            exit(0)
        }
        
        // Generate YUL IR code.
        let irCode = IRCodeGenerator(topLevelModule: passRunnerOutcome.element, environment: passRunnerOutcome.environment)
            .generateCode()
        
        // Compile the YUL IR code using solc.
        try SolcCompiler(inputSource: irCode, outputDirectory: config.outputDirectory, emitBytecode: false).compile()
        
        // these are warnings from the solc compiler
        try config.diagnostics.display()
        
        let fileName = "main.sol"
        let irFileURL: URL
        irFileURL = config.outputDirectory.appendingPathComponent(fileName)
        do {
            try irCode.write(to: irFileURL, atomically: true, encoding: .utf8)
        } catch {
            exitWithUnableToWriteIRFile(irFileURL: irFileURL)
        }
    }

}


// MARK: Compile hook for language server
extension Compiler {
    public static func ide_compile(config: CompilerLSPConfiguration) throws -> [Diagnostic]
    {
        let tokens = try tokenizeSourceCode(sourceFile: config.sourceFiles[0], sourceCode: config.sourceCode)
        
        // Turn the tokens into an Abstract Syntax Tree (AST).
        let (parserAST, environment, parserDiagnostics) = Parser(tokens: tokens).parse()
        
        // add all parser diagnostics to the pool of diagnistics
        config.diagnostics.appendAll(parserDiagnostics)
        
        // stop parsing if any syntax errors are detected
        if (environment.syntaxErrors)
        {
            let diag = config.diagnostics
            return diag.getDiagnostics()
        }
        
        guard let ast = parserAST else {
            return config.diagnostics.getDiagnostics()
        }
 
        
        let passRunnerOutcome = ASTPassRunner(ast: ast)
            .run(passes: config.astPasses,
                 in: environment,
                 sourceContext: SourceContext(sourceFiles: config.sourceFiles,
                                              sourceCodeString: config.sourceCode,
                                              isForServer: true))
        
        // add semantic diagnostics
        config.diagnostics.appendAll(passRunnerOutcome.diagnostics)
        
        return config.diagnostics.getDiagnostics()
    }
}

// MARK: - Configurations
public struct DiagnoserConfiguration {
  public let inputFiles: [URL]
  public let astPasses: [ASTPass]

  public init(inputFiles: [URL],
              astPasses: [ASTPass] = Compiler.defaultASTPasses) {
    self.inputFiles = inputFiles
    self.astPasses = astPasses
  }
}

public struct CompilerLSPConfiguration {
    public let sourceFiles: [URL]
    public let sourceCode: String
    public let stdlibFiles: [URL]
    public let diagnostics: DiagnosticPool
    public let astPasses: [ASTPass]
    
    public init(sourceFiles : [URL],
                sourceCode : String,
                stdlibFiles : [URL],
                diagnostics: DiagnosticPool,
                astPasses : [ASTPass] = Compiler.defaultASTPasses) {
        self.sourceFiles = sourceFiles
        self.sourceCode = sourceCode
        self.stdlibFiles = stdlibFiles
        self.diagnostics = diagnostics
        self.astPasses = astPasses
    }
}

public struct CompilerReplConfiguration {
    public let sourceFiles: [URL]
    public let stdlibFiles: [URL]
    public let outputDirectory : URL
    public let diagnostics: DiagnosticPool
    public let astPasses: [ASTPass]
    
    public init(sourceFiles : [URL],
                stdlibFiles : [URL],
                outputDirectory: URL,
                diagnostics: DiagnosticPool,
                astPasses : [ASTPass] = Compiler.defaultASTPasses) {
        self.sourceFiles = sourceFiles
        self.stdlibFiles = stdlibFiles
        self.outputDirectory = outputDirectory
        self.diagnostics = diagnostics
        self.astPasses = astPasses
    }
    
}

public struct CompilerContractAnalyserConfiguration {
    public let sourceFiles: [URL]
    public let sourceCode: String
    public let stdlibFiles: [URL]
    public let outputDirectory : URL
    public let diagnostics: DiagnosticPool
    public let astPasses: [ASTPass]
    
    public init(sourceFiles : [URL],
                sourceCode : String,
                stdlibFiles : [URL],
                outputDirectory: URL,
                diagnostics: DiagnosticPool,
                astPasses : [ASTPass] = Compiler.defaultASTPasses) {
        self.sourceFiles = sourceFiles
        self.sourceCode = sourceCode
        self.stdlibFiles = stdlibFiles
        self.outputDirectory = outputDirectory
        self.diagnostics = diagnostics
        self.astPasses = astPasses
    }
}

public struct CompilerTestFrameworkConfiguration {
    public let sourceFiles: [URL]
    public let sourceCode: String
    public let stdlibFiles: [URL]
    public let outputDirectory: URL
    public let diagnostics: DiagnosticPool
    public let astPasses: [ASTPass]
    
    public init(sourceFiles : [URL],
                sourceCode : String,
                stdlibFiles : [URL],
                outputDirectory: URL,
                diagnostics: DiagnosticPool,
                astPasses : [ASTPass] = Compiler.defaultASTPasses) {
        self.sourceFiles = sourceFiles
        self.sourceCode = sourceCode
        self.stdlibFiles = stdlibFiles
        self.outputDirectory = outputDirectory
        self.diagnostics = diagnostics
        self.astPasses = astPasses
    }
}

public struct CompilerConfiguration {
  public let inputFiles: [URL]
  public let stdlibFiles: [URL]
  public let outputDirectory: URL
  public let dumpAST: Bool
  public let emitBytecode: Bool
  public let dumpVerifierIR: Bool
  public let printVerificationOutput: Bool
  public let skipHolisticCheck: Bool
  public let skipVerifier: Bool
  public let printHolisticRunStats: Bool
  public let maxHolisticTimeout: Int
  public let maxTransactionDepth: Int
  public let skipCodeGen: Bool
  public let diagnostics: DiagnosticPool
  public let loadStdlib: Bool
  public let astPasses: [ASTPass]

  public init(inputFiles: [URL],
              stdlibFiles: [URL],
              outputDirectory: URL,
              dumpAST: Bool,
              emitBytecode: Bool,
              dumpVerifierIR: Bool,
              printVerificationOutput: Bool,
              skipHolisticCheck: Bool,
              printHolisticRunStats: Bool,
              maxHolisticTimeout: Int,
              maxTransactionDepth: Int,
              skipVerifier: Bool,
              skipCodeGen: Bool,
              diagnostics: DiagnosticPool,
              loadStdlib: Bool = true,
              astPasses: [ASTPass] = Compiler.defaultASTPasses) {
    self.inputFiles = inputFiles
    self.stdlibFiles = stdlibFiles
    self.outputDirectory = outputDirectory
    self.dumpAST = dumpAST
    self.emitBytecode = emitBytecode
    self.dumpVerifierIR = dumpVerifierIR
    self.printVerificationOutput = printVerificationOutput
    self.skipHolisticCheck = skipHolisticCheck
    self.printHolisticRunStats = printHolisticRunStats
    self.maxHolisticTimeout = maxHolisticTimeout
    self.maxTransactionDepth = maxTransactionDepth
    self.skipVerifier = skipVerifier
    self.skipCodeGen = skipCodeGen
    self.diagnostics = diagnostics
    self.astPasses = astPasses
    self.loadStdlib = loadStdlib
  }
}

public struct CompilationOutcome {
  public var irCode: String
  public var astDump: String
}
