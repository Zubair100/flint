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
import SemanticAnalyzer
import TypeChecker
import Optimizer
import LSP
import IRGen

/// Runs the different stages of the compiler.
struct Compiler {
  var sourceFiles: [URL]
  var sourceCode: String
  var stdlibFiles: [URL]
  var diagnostics: DiagnosticPool


  var sourceContext: SourceContext {
    return SourceContext(sourceFiles: sourceFiles, sourceCodeString: sourceCode, isForServer: true)
  }

  func tokenizeFiles() throws -> [Token] {
    let stdlibTokens = try StandardLibrary.default.files.flatMap { try Lexer(sourceFile: $0, isFromStdlib: true).lex() }
    let userTokens = try Lexer(sourceFile: sourceFiles[0], isFromStdlib: false, isForServer: true, sourceCode: sourceCode).lex()
    return stdlibTokens + userTokens
  }
    
  func ide_compile() throws
  {
    let tokens = try tokenizeFiles()

    // Turn the tokens into an Abstract Syntax Tree (AST).
    let (parserAST, environment, parserDiagnostics) = Parser(tokens: tokens).parse()
    
    // add all parser diagnostics to the pool of diagnistics  
    diagnostics.appendAll(parserDiagnostics)
    
    // stop parsing if any syntax errors are detected
    if (environment.syntaxErrors)
    {
        let diag = diagnostics
        let lsp_json = try convertFlintDiagToLspDiagJson(diag.getDiagnostics())
        print(lsp_json)
        return
    }
    
    guard let ast = parserAST else {
        return
    }
    
    let astPasses: [ASTPass] = [
        SemanticAnalyzer(),
        TypeChecker(),
        Optimizer(),
        IRPreprocessor()
    ]
    
    let passRunnerOutcome = ASTPassRunner(ast: ast)
        .run(passes: astPasses, in: environment, sourceContext: sourceContext)

    // add semantic diagnostics
    diagnostics.appendAll(passRunnerOutcome.diagnostics)
        
    let lsp_json = try convertFlintDiagToLspDiagJson(diagnostics.getDiagnostics())
    print(lsp_json)

    // all the diagnostics have been added
    return
  }
}
