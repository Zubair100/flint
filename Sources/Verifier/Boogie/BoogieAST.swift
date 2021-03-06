import Source
import Foundation

import BigInt

typealias SourceMapping = Set<TranslationInformation>

struct BTopLevelProgram {
  let declarations: [BTopLevelDeclaration]

  func render() -> (String, [Int: TranslationInformation]) {
    let a = declarations.map({ $0.render() })
    let (string, mapping) = a.reduce(("// Generated by flintc\n", Set<TranslationInformation>())) { x, y in
                                                                       return ("\(x.0)\n\n\(y.0)", x.1.union(y.1))
    }
    return (string, generateFlint2BoogieMapping(code: string, proofObligationMapping: mapping))
  }

  private func generateFlint2BoogieMapping(code: String,
                                           proofObligationMapping: Set<TranslationInformation>) -> [Int: TranslationInformation] {
    var mapping = [Int: TranslationInformation]()
    var proofObligationMapping = Dictionary(uniqueKeysWithValues: proofObligationMapping.map({ ($0.hashValue, $0) }))

    let lines = code.trimmingCharacters(in: .whitespacesAndNewlines)
                               .components(separatedBy: "\n")
    var boogieLine = 1 // Boogie starts counting lines from 1
    for line in lines {
      // Pre increment because assert markers precede asserts and pre/post condits
      boogieLine += 1

      // Look for ASSERT markers
      let matches = line.groups(for: TranslationInformation.regexString)
      if matches.count == 1 {
        // Extract line number
        let tiHash = Int(matches[0][1])!

        guard let translationInformation = proofObligationMapping[tiHash] else {
          print("Couldn't find marker for proof obligation")
          print(proofObligationMapping)
          print(tiHash)
          fatalError()
        }
        mapping[boogieLine] = translationInformation
      }
    }
    return mapping
  }
}

enum BTopLevelDeclaration {
  case functionDeclaration(BFunctionDeclaration)
  case axiomDeclaration(BAxiomDeclaration)
  case variableDeclaration(BVariableDeclaration)
  case constDeclaration(BConstDeclaration)
  case typeDeclaration(BTypeDeclaration)
  case procedureDeclaration(BProcedureDeclaration)

  func render() -> (String, SourceMapping) {
    switch self {
    case .functionDeclaration(let bFunctionDeclaration):
      return bFunctionDeclaration.render()
    case .axiomDeclaration(let bAxiomDeclaration):
      return bAxiomDeclaration.render()
    case .variableDeclaration(let bVariableDeclaration):
      return bVariableDeclaration.render()
    case .constDeclaration(let bConstDeclaration):
      return bConstDeclaration.render()
    case .typeDeclaration(let bTypeDeclaration):
      return bTypeDeclaration.render()
    case .procedureDeclaration(let bProcedureDeclaration):
      return bProcedureDeclaration.render()
    }
  }
}

struct BFunctionDeclaration {
  let name: String
  let returnType: BType?
  let returnName: String?
  let parameters: [BParameterDeclaration]

  func render() -> (String, SourceMapping) {
    let parameterString = parameters.map({(x) -> String in return x.description}).joined(separator: ", ")
    let returnComponent = returnType == nil ? " " : " returns (\(returnName!): \(returnType!))"
    return ("function \(name)(\(parameterString))\(returnComponent);", Set<TranslationInformation>())
  }
}

struct BAxiomDeclaration {
  let proposition: BExpression

  func render() -> (String, SourceMapping) {
    return ("axiom \(proposition);", Set<TranslationInformation>())
  }
}

struct BVariableDeclaration: Hashable {
  let name: String
  let rawName: String
  let type: BType

  func render() -> (String, SourceMapping) {
    return ("var \(name): \(type);", Set<TranslationInformation>())
  }

  var hashValue: Int {
    return self.rawName.hashValue
  }
}

struct BConstDeclaration {
  let name: String
  let rawName: String
  let type: BType
  let unique: Bool

  func render() -> (String, SourceMapping) {
    return ("const \(unique ? "unique" : "") \(name): \(type);", Set<TranslationInformation>())
  }
}

struct BTypeDeclaration {
  let name: String
  let alias: BType?

  func render() -> (String, SourceMapping) {
    let aliasString = alias == nil ? "" : "= \(alias!)"
    return ("type \(name) \(aliasString);", Set<TranslationInformation>())
  }
}

struct BPreCondition {
  let expression: BExpression
  let ti: TranslationInformation
  let free: Bool

  init(expression: BExpression, ti: TranslationInformation) {
    self.expression = expression
    self.ti = ti
    self.free = false
  }

  init(expression: BExpression, ti: TranslationInformation, free: Bool) {
    self.expression = expression
    self.ti = ti
    self.free = free
  }

  func render() -> (String, SourceMapping) {
    return ("\(ti)\n\(free ? "free " : "")requires (\(expression));", Set([ti]))
  }
}

struct BPostCondition {
  let expression: BExpression
  let ti: TranslationInformation

  func render() -> (String, SourceMapping) {
    return ("\(ti)\nensures (\(expression));", Set([ti]))
  }
}

struct BAssertStatement {
  let expression: BExpression
  let ti: TranslationInformation

  func render() -> (String, SourceMapping) {
    return ("\(ti)\nassert (\(expression));", Set([ti]))
  }
}

struct BLoopInvariant {
  let expression: BExpression
  let ti: TranslationInformation

  func render() -> (String, SourceMapping) {
    return ("\(ti)\ninvariant (\(expression));", Set([ti]))
  }
}

struct BProcedureDeclaration {
  let name: String
  let returnTypes: [BType]?
  let returnNames: [String]?
  let parameters: [BParameterDeclaration]
  let preConditions: [BPreCondition]
  let postConditions: [BPostCondition]
  let modifies: Set<BModifiesDeclaration>
  let statements: [BStatement]
  let variables: Set<BVariableDeclaration>
  let inline: Bool
  let ti: TranslationInformation

  private let procedureInlineDepth: Int = 10

  func render() -> (String, SourceMapping) {
    let parameterString = parameters.map({(x) -> String in return x.description}).joined(separator: ", ")
    let modifiesString = modifies.reduce("", {x, y in "\(x)\n\(y)"})

    var returnString: String
    if let types = returnTypes, let names = returnNames {
      assert(types.count == names.count)

      returnString = ""
      for (name, type) in zip(names, types) {
        returnString = "\(returnString), \(name): \(type)"
      }
      returnString.removeFirst(1)

      returnString = " returns (\(returnString))"
    } else {
      returnString = ""
    }
    let (variablesString, variablesMapping) = variables
      .map({ $0.render() }).reduce(("", Set<TranslationInformation>()), { x, y in
                                     return ("\(x.0)\n\(y.0)", x.1.union(y.1))
                                   })

    let (statementsString, statementsMapping) = statements
      .map({ $0.render() }).reduce(("", Set<TranslationInformation>()), { x, y in
                                     return ("\(x.0)\n\(y.0)", x.1.union(y.1))
                                   })
    let (preString, preMapping) = preConditions
      .map({ $0.render() }).reduce(("", Set<TranslationInformation>()), { x, y in
                                     return ("\(x.0)\n\(y.0)", x.1.union(y.1))
                                   })
    let (postString, postMapping) = postConditions
      .map({ $0.render() }).reduce(("", Set<TranslationInformation>()), { x, y in
                                     return ("\(x.0)\n\(y.0)", x.1.union(y.1))
                                   })
    let procedureMapping = preMapping.union(postMapping)
                                     .union(statementsMapping)
                                     .union(variablesMapping)
                                     .union(Set([ti]))

    let inlineAnnotation = inline ? "{:inline \(procedureInlineDepth)}" : ""

    let procedureString =  """
    procedure \(inlineAnnotation) \(name)(\(parameterString))\(returnString)
      // Pre Conditions
      \(preString)
      // Post Conditions
      \(postString)
      // Modifies
      \(modifiesString)
    {
    // Local variable declarations
    \(variablesString)

    // \(name)'s implementation
    \(statementsString)
    \(ti)
    }
    """

    return (procedureString, procedureMapping)
  }
}

struct BModifiesDeclaration: CustomStringConvertible, Hashable {
  // Name of global variable being modified
  let variable: String

  var description: String {
    return "modifies \(variable);"
  }

  var hashValue: Int {
    return variable.hashValue
  }
}

struct BParameterDeclaration: CustomStringConvertible {
  let name: String
  let rawName: String
  let type: BType

  var description: String {
    return "\(name): \(type)"
  }
}

struct BCallProcedure {
  let returnedValues: [String]
  let procedureName: String
  let arguments: [BExpression]
  let ti: TranslationInformation

  func render() -> (String, SourceMapping) {
    let argumentComponent = arguments.map({(x) -> String in x.description}).joined(separator: ", ")
    var returnValuesComponent = ""
    if returnedValues.count > 0 {
      returnValuesComponent = "\(returnedValues.joined(separator: ", ")) := "
    }

    return ("\(ti)\ncall \(returnValuesComponent) \(procedureName)(\(argumentComponent));",
            Set([ti]))
  }

}

enum BStatement {
  case expression(BExpression, TranslationInformation)
  case ifStatement(BIfStatement)
  case whileStatement(BWhileStatement)
  case assertStatement(BAssertStatement)
  case assume(BExpression, TranslationInformation)
  case havoc(String, TranslationInformation)
  case assignment(BExpression, BExpression, TranslationInformation)
  case callProcedure(BCallProcedure)
  case breakStatement

  func render() -> (String, SourceMapping) {
    switch self {
    case .expression(let expression, let ti):
      return ("\(ti)\n\(expression)", Set([ti]))
    case .ifStatement(let ifStatement):
      return ifStatement.render()
    case .whileStatement(let whileStatement):
      return whileStatement.render()
    case .assertStatement(let assertion):
    return assertion.render()
    case .assume(let assumption, let ti):
      return ("\(ti)\nassume (\(assumption));", Set([ti]))
    case .havoc(let identifier, let ti):
      return ("\(ti)\nhavoc \(identifier);", Set([ti]))
    case .assignment(let lhs, let rhs, let ti):
      return ("\(ti)\n\(lhs) := \(rhs);", Set([ti]))
    case .callProcedure(let callProcedure):
      return callProcedure.render()
    case .breakStatement:
      return ("break;", Set<TranslationInformation>())
    }
  }
}

indirect enum BExpression: CustomStringConvertible {
  case equivalent(BExpression, BExpression)
  case implies(BExpression, BExpression)
  case or(BExpression, BExpression)
  case and(BExpression, BExpression)
  case equals(BExpression, BExpression)
  case lessThan(BExpression, BExpression)
  case lessThanOrEqual(BExpression, BExpression)
  case greaterThan(BExpression, BExpression)
  case greaterThanOrEqual(BExpression, BExpression)
  case concat(BExpression, BExpression)
  case add(BExpression, BExpression)
  case subtract(BExpression, BExpression)
  case multiply(BExpression, BExpression)
  case divide(BExpression, BExpression)
  case modulo(BExpression, BExpression)
  case not(BExpression)
  case negate(BExpression)
  case mapRead(BExpression, BExpression)
  case boolean(Bool)
  case integer(BigUInt)
  case real(Int, Int)
  case identifier(String)
  case old(BExpression)
  case quantified(BQuantifier, [BParameterDeclaration], BExpression)
  case functionApplication(String, [BExpression])
  case nop

  var description: String {
    switch self {
    case .equivalent(let lhs, let rhs): return "(\(lhs) <==> \(rhs))"
    case .implies(let lhs, let rhs): return "(\(lhs) ==> \(rhs))"
    case .or(let lhs, let rhs): return "(\(lhs) || \(rhs))"
    case .and(let lhs, let rhs): return "(\(lhs) && \(rhs))"
    case .equals(let lhs, let rhs): return "(\(lhs) == \(rhs))"
    case .lessThan(let lhs, let rhs): return "(\(lhs) < \(rhs))"
    case .lessThanOrEqual(let lhs, let rhs): return "(\(lhs) <= \(rhs))"
    case .greaterThan(let lhs, let rhs): return "(\(lhs) > \(rhs))"
    case .greaterThanOrEqual(let lhs, let rhs): return "(\(lhs) >= \(rhs))"
    case .concat(let lhs, let rhs): return "(\(lhs) ++ \(rhs))"
    case .add(let lhs, let rhs): return "(\(lhs) + \(rhs))"
    case .subtract(let lhs, let rhs): return "(\(lhs) - \(rhs))"
    case .multiply(let lhs, let rhs): return "(\(lhs) * \(rhs))"
    case .divide(let lhs, let rhs): return "(\(lhs) div \(rhs))"
    case .modulo(let lhs, let rhs): return "(\(lhs) mod \(rhs))"
    case .not(let expression): return "(!\(expression))"
    case .negate(let expression): return "(-\(expression))"
    case .mapRead(let map, let key): return "\(map)[\(key)]"
    case .boolean(let bool): return "\(bool)"
    case .integer(let int): return "\(int)"
    case .real(let b, let f): return "\(b).\(f)"
    case .identifier(let string): return string
    case .old(let expression): return "old(\(expression))"
    case .nop: return "// nop"
    case .quantified(let quantifier, let parameterDeclaration, let expression):
      let parameterDeclarationComponent
        = parameterDeclaration.map({(x) -> String in x.description}).joined(separator: ", ")
      return "(\(quantifier) \(parameterDeclarationComponent) :: \(expression))"
    case .functionApplication(let functionName, let arguments):
      let argumentsComponent = arguments.map({(x) -> String in x.description}).joined(separator: ", ")
      return "\(functionName)(\(argumentsComponent))"
    }
  }
}

enum BQuantifier {
  case forall
  case exists

  var description: String {
    switch self {
    case .forall:
      return "forall"
    case .exists:
      return "exists"
    }
  }
}

struct BIfStatement {
  let condition: BExpression
  let trueCase: [BStatement]
  let falseCase: [BStatement]
  let ti: TranslationInformation

  func render() -> (String, SourceMapping) {
    let (trueString, trueMapping) = trueCase
      .map({ $0.render() }).reduce(("", Set<TranslationInformation>()), { x, y in
                                     return ("\(x.0)\n\(y.0)", x.1.union(y.1))
                                   })

    let (falseString, falseMapping) = falseCase
      .map({ $0.render() }).reduce(("", Set<TranslationInformation>()), { x, y in
                                     return ("\(x.0)\n\(y.0)", x.1.union(y.1))
                                   })
    let ifString = """
    \(ti)
    if (\(condition)) {
      \(trueString)
      \(ti)
    } else {
      \(falseString)
      \(ti)
    }
    """
    return (ifString, trueMapping.union(Set([ti])).union(falseMapping))
  }
}

struct BWhileStatement {
  let condition: BExpression
  let body: [BStatement]
  let invariants: [BLoopInvariant]
  let ti: TranslationInformation

  func render() -> (String, SourceMapping) {
    let (invariantString, invariantMapping) = invariants
      .map({ $0.render() }).reduce(("", Set<TranslationInformation>()), { x, y  in
                                     return (x.0 + "\n" + y.0, x.1.union(y.1))
                                   })
    let (bodyString, bodyMapping) = body
      .map({ $0.render() }).reduce(("", Set<TranslationInformation>()), { x, y in
                                     return ("\(x.0)\n\(y.0)", x.1.union(y.1))
                                   })
    let whileString =  """
    \(ti)
    while(\(condition))
    // Loop invariants
    \(invariantString)
    {
      \(bodyString)
    }
    """
    return (whileString, invariantMapping.union(bodyMapping).union(Set([ti])))
  }
}

indirect enum BType: CustomStringConvertible, Hashable {
  case int
  case real
  case boolean
  case userDefined(String)
  case map(BType, BType)

  var description: String {
    switch self {
    case .int: return "int"
    case .real: return "real"
    case .boolean: return "bool"
    case .userDefined(let type): return type
    case .map(let type1, let type2): return "[\(type1)]\(type2)"
    }
  }

  var nameSafe: String {
    switch self {
    case .int: return "int"
    case .real: return "real"
    case .boolean: return "bool"
    case .userDefined(let type): return type
    case .map(let type1, let type2): return "\(type1.nameSafe)_\(type2.nameSafe)"
    }
  }

  var hashValue: Int {
    return self.description.hashValue
  }
}
