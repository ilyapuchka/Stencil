import Foundation

class ForNode : NodeType {
  let resolvable: Resolvable
  let loopVariables: [String]
  let nodes:[NodeType]
  let emptyNodes: [NodeType]
  let `where`: Expression?

  class func parse(_ parser:TokenParser, token:Token) throws -> NodeType {
    var components = token.components()
    
    let error = TemplateSyntaxError("'for' statements should use the following 'for x in y where condition' `\(token.contents)`.")
    guard components.count >= 3 else { throw error }

    // this will allow using comma with spaces between loop variables
    if components[1].hasSuffix(",") {
      components[1] = "\(components[1])\(components.remove(at: 2))"
    }
    
    guard components[2] == "in" && (components.count == 4 || (components.count >= 6 && components[4] == "where")) else {
      throw error
    }

    let loopVariables = components[1].characters
      .split(separator: ",")
      .map(String.init)
      .map { $0.trimmingCharacters(in: CharacterSet.whitespaces) }

    let variable = components[3]

    var emptyNodes = [NodeType]()

    let forNodes = try parser.parse(until(["endfor", "empty"]))

    guard let token = parser.nextToken() else {
      throw TemplateSyntaxError("`endfor` was not found.")
    }

    if token.contents == "empty" {
      emptyNodes = try parser.parse(until(["endfor"]))
      _ = parser.nextToken()
    }

    let filter = try parser.compileFilter(variable)
    let `where`: Expression?
    if components.count >= 6 {
      `where` = try parseExpression(components: Array(components.suffix(from: 5)), tokenParser: parser)
    } else {
      `where` = nil
    }
    return ForNode(resolvable: filter, loopVariables: loopVariables, nodes: forNodes, emptyNodes:emptyNodes, where: `where`)
  }

  init(resolvable: Resolvable, loopVariables: [String], nodes:[NodeType], emptyNodes:[NodeType], where: Expression? = nil) {
    self.resolvable = resolvable
    self.loopVariables = loopVariables
    self.nodes = nodes
    self.emptyNodes = emptyNodes
    self.where = `where`
  }

  func push<Result>(value: Any, context: Context, closure: () throws -> (Result)) rethrows -> Result {
    if loopVariables.isEmpty {
      return try context.push() {
        return try closure()
      }
    }

    if let value = value as? (Any, Any) {
      let first = loopVariables[0]

      if loopVariables.count == 2 {
        let second = loopVariables[1]

        return try context.push(dictionary: [first: value.0, second: value.1]) {
          return try closure()
        }
      }

      return try context.push(dictionary: [first: value.0]) {
        return try closure()
      }
    }

    return try context.push(dictionary: [loopVariables.first!: value]) {
      return try closure()
    }
  }

  func render(_ context: Context) throws -> String {
    let resolved = try resolvable.resolve(context)

    var values: [Any]

    if let dictionary = resolved as? [String: Any], !dictionary.isEmpty {
      values = dictionary.map { ($0.key, $0.value) }
    } else if let array = resolved as? [Any] {
      if loopVariables.count == 2 {
        values = array.enumerated().map({ ($0.offset, $0.element) })
      } else {
        values = array
      }
    } else if let range = resolved as? CountableClosedRange<Int> {
      values = Array(range)
    } else if let range = resolved as? CountableRange<Int> {
      values = Array(range)
    } else if let resolved = resolved {
      let mirror = Mirror(reflecting: resolved)
      switch mirror.displayStyle {
      case .struct?, .tuple?:
        values = Array(mirror.children)
      case .class?:
        var children = Array(mirror.children)
        var currentMirror: Mirror? = mirror
        while let superclassMirror = currentMirror?.superclassMirror {
          children.append(contentsOf: superclassMirror.children)
          currentMirror = superclassMirror
        }
        values = Array(children)
      default:
        values = []
      }
    } else {
      values = []
    }

    if let `where` = self.where {
      values = try values.filter({ item -> Bool in
        return try push(value: item, context: context) {
          try `where`.evaluate(context: context)
        }
      })
    }

    if !values.isEmpty {
      let count = values.count

      return try values.enumerated().map { index, item in
        let forContext: [String: Any] = [
          "first": index == 0,
          "last": index == (count - 1),
          "counter": index + 1,
          "counter0": index,
          "length": count
        ]

        return try context.push(dictionary: ["forloop": forContext]) {
          return try push(value: item, context: context) {
            try renderNodes(nodes, context)
          }
        }
      }.joined(separator: "")
    }

    return try context.push {
      try renderNodes(emptyNodes, context)
    }
  }
}
