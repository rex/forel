import Foundation
import ForelCore
import Yams

// The YAML schema mirrors Forel's own tables and uses the database's raw enum
// strings, so anything the engine accepts can be written here verbatim:
//
//   folders:
//     - path: ~/Downloads
//       rules:
//         - name: Screenshots
//           match: all            # all | any (default all)
//           depth: 0              # 0 this folder only, N levels deep, -1 unlimited
//           conditions:
//             - { kind: name, operator: starts_with, value: "Screenshot" }
//             - { kind: extension, operator: is, value: png }
//           actions:
//             - { kind: move_to_folder, params: { destination: ~/Pictures/Screenshots } }

struct RulesFile: Decodable {
    var folders: [FolderSpec]
}

struct FolderSpec: Decodable {
    var path: String
    var rules: [RuleSpec]?
}

struct RuleSpec: Decodable {
    var name: String
    var enabled: Bool?
    var match: ConditionMatch?
    var depth: Int64?
    var conditions: [ConditionSpec]?
    var actions: [ActionSpec]?
}

struct ConditionSpec: Decodable {
    var kind: ConditionKind
    var op: Operator
    var value: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case op = "operator"
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ConditionKind.self, forKey: .kind)
        op = try container.decode(Operator.self, forKey: .op)
        value = try container.decode(LooseString.self, forKey: .value).string
    }
}

struct ActionSpec: Decodable {
    var kind: ActionKind
    var params: JSONValue?
}

/// YAML types its scalars (`300`, `true`); Forel stores every condition value as text.
struct LooseString: Decodable {
    let string: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            string = text
        } else if let integer = try? container.decode(Int.self) {
            string = String(integer)
        } else if let number = try? container.decode(Double.self) {
            string = String(number)
        } else if let flag = try? container.decode(Bool.self) {
            string = String(flag)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "condition value must be a scalar")
        }
    }
}

// The same shape going out (`foreld dump`), with defaults omitted so the file
// stays as short as a hand-written one.

struct RulesDocument: Encodable {
    var folders: [FolderOut]
}

struct FolderOut: Encodable {
    var path: String
    var rules: [RuleOut]
}

struct RuleOut: Encodable {
    var name: String
    var enabled: Bool?
    var match: String?
    var depth: Int64?
    var conditions: [ConditionOut]
    var actions: [ActionOut]
}

struct ConditionOut: Encodable {
    var kind: String
    var op: String
    var value: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case op = "operator"
        case value
    }
}

struct ActionOut: Encodable {
    var kind: String
    var params: JSONValue
}

enum RulesLoader {
    static func load(_ file: String) throws -> RulesFile {
        let text = try String(contentsOfFile: expandPath(file), encoding: .utf8)
        return try YAMLDecoder().decode(RulesFile.self, from: text)
    }

    /// Forel model objects for one rule. `id` is carried over between applies
    /// so history keeps pointing at the same rule.
    static func makeRule(_ spec: RuleSpec, folderId: String, id: String, priority: Int64) -> Rule {
        let depth = spec.depth ?? 0
        var rule = Rule(
            id: id,
            folderId: folderId,
            name: spec.name,
            enabled: spec.enabled ?? true,
            conditionMatch: spec.match ?? .all,
            recursionDepth: depth < 0 ? nil : depth,
            priority: priority
        )
        rule.conditions = (spec.conditions ?? []).map { condition in
            Condition(ruleId: id, kind: condition.kind, operator: condition.op, value: condition.value)
        }
        rule.actions = (spec.actions ?? []).enumerated().map { index, action in
            Action(ruleId: id, kind: action.kind, params: expandPaths(in: action.params ?? .object([:])), position: Int64(index))
        }
        return rule
    }

    /// `~` in destination and application paths, so the file reads like a shell.
    private static func expandPaths(in params: JSONValue) -> JSONValue {
        guard case .object(var dictionary) = params else { return params }
        for key in [ActionParam.destination, ActionParam.applicationPath] {
            if case .string(let value)? = dictionary[key], value.hasPrefix("~") {
                dictionary[key] = .string(expandPath(value))
            }
        }
        return .object(dictionary)
    }
}
