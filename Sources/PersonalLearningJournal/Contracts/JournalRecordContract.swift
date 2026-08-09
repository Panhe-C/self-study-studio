import Foundation

/// The public A2 name for the existing JournalEntityKind enumeration.
///
/// Keeping this alias means the CloudKit record-kind vocabulary stays stable while
/// the shared contract can use the language used by the Web Workspace.
public typealias JournalRecordKind = JournalEntityKind

public struct JournalRecordFieldDefinition: Codable, Equatable, Sendable {
    public let type: String
    public let isRequired: Bool
    public let trim: Bool
    public let nonEmpty: Bool
    public let values: [String]?
    public let variants: [String]?
    public let minimum: Int?
    public let maximum: Int?
    public let sort: String?
    public let items: JournalRecordNestedFieldDefinition?
    public let objectFields: [String: JournalRecordNestedFieldDefinition]?
    public let variantFields: [String: [String: JournalRecordNestedFieldDefinition]]?

    private enum CodingKeys: String, CodingKey {
        case type
        case isRequired = "required"
        case trim
        case nonEmpty
        case values
        case variants
        case minimum
        case maximum
        case sort
        case items
        case objectFields
        case variantFields
    }

    public init(
        type: String,
        isRequired: Bool,
        trim: Bool = false,
        nonEmpty: Bool = false,
        values: [String]? = nil,
        variants: [String]? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil,
        sort: String? = nil,
        items: JournalRecordNestedFieldDefinition? = nil,
        objectFields: [String: JournalRecordNestedFieldDefinition]? = nil,
        variantFields: [String: [String: JournalRecordNestedFieldDefinition]]? = nil
    ) {
        self.type = type
        self.isRequired = isRequired
        self.trim = trim
        self.nonEmpty = nonEmpty
        self.values = values
        self.variants = variants
        self.minimum = minimum
        self.maximum = maximum
        self.sort = sort
        self.items = items
        self.objectFields = objectFields
        self.variantFields = variantFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try container.decode(String.self, forKey: .type),
            isRequired: try container.decode(Bool.self, forKey: .isRequired),
            trim: try container.decodeIfPresent(Bool.self, forKey: .trim) ?? false,
            nonEmpty: try container.decodeIfPresent(Bool.self, forKey: .nonEmpty) ?? false,
            values: try container.decodeIfPresent([String].self, forKey: .values),
            variants: try container.decodeIfPresent([String].self, forKey: .variants),
            minimum: try container.decodeIfPresent(Int.self, forKey: .minimum),
            maximum: try container.decodeIfPresent(Int.self, forKey: .maximum),
            sort: try container.decodeIfPresent(String.self, forKey: .sort),
            items: try container.decodeIfPresent(JournalRecordNestedFieldDefinition.self, forKey: .items),
            objectFields: try container.decodeIfPresent([String: JournalRecordNestedFieldDefinition].self, forKey: .objectFields),
            variantFields: try container.decodeIfPresent([String: [String: JournalRecordNestedFieldDefinition]].self, forKey: .variantFields)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(isRequired, forKey: .isRequired)
        try container.encode(trim, forKey: .trim)
        try container.encode(nonEmpty, forKey: .nonEmpty)
        try container.encodeIfPresent(values, forKey: .values)
        try container.encodeIfPresent(variants, forKey: .variants)
        try container.encodeIfPresent(minimum, forKey: .minimum)
        try container.encodeIfPresent(maximum, forKey: .maximum)
        try container.encodeIfPresent(sort, forKey: .sort)
        try container.encodeIfPresent(items, forKey: .items)
        try container.encodeIfPresent(objectFields, forKey: .objectFields)
        try container.encodeIfPresent(variantFields, forKey: .variantFields)
    }
}

/// A recursive schema node for finite nested values in the shared contract.
/// `items` describes array members and `objectFields` describes object
/// members, keeping Swift and Web on one strict schema.
public final class JournalRecordNestedFieldDefinition: Codable, Equatable, @unchecked Sendable {
    public let type: String
    public let isRequired: Bool
    public let trim: Bool
    public let nonEmpty: Bool
    public let values: [String]?
    public let minimum: Int?
    public let maximum: Int?
    public let format: String?
    public let items: JournalRecordNestedFieldDefinition?
    public let objectFields: [String: JournalRecordNestedFieldDefinition]?

    private enum CodingKeys: String, CodingKey {
        case type
        case isRequired = "required"
        case trim
        case nonEmpty
        case values
        case minimum
        case maximum
        case format
        case items
        case objectFields
    }

    public init(
        type: String,
        isRequired: Bool,
        trim: Bool = false,
        nonEmpty: Bool = false,
        values: [String]? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil,
        format: String? = nil,
        items: JournalRecordNestedFieldDefinition? = nil,
        objectFields: [String: JournalRecordNestedFieldDefinition]? = nil
    ) {
        self.type = type
        self.isRequired = isRequired
        self.trim = trim
        self.nonEmpty = nonEmpty
        self.values = values
        self.minimum = minimum
        self.maximum = maximum
        self.format = format
        self.items = items
        self.objectFields = objectFields
    }

    public static func == (
        lhs: JournalRecordNestedFieldDefinition,
        rhs: JournalRecordNestedFieldDefinition
    ) -> Bool {
        lhs.type == rhs.type
            && lhs.isRequired == rhs.isRequired
            && lhs.trim == rhs.trim
            && lhs.nonEmpty == rhs.nonEmpty
            && lhs.values == rhs.values
            && lhs.minimum == rhs.minimum
            && lhs.maximum == rhs.maximum
            && lhs.format == rhs.format
            && lhs.items == rhs.items
            && lhs.objectFields == rhs.objectFields
    }

    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try container.decode(String.self, forKey: .type),
            isRequired: try container.decode(Bool.self, forKey: .isRequired),
            trim: try container.decodeIfPresent(Bool.self, forKey: .trim) ?? false,
            nonEmpty: try container.decodeIfPresent(Bool.self, forKey: .nonEmpty) ?? false,
            values: try container.decodeIfPresent([String].self, forKey: .values),
            minimum: try container.decodeIfPresent(Int.self, forKey: .minimum),
            maximum: try container.decodeIfPresent(Int.self, forKey: .maximum),
            format: try container.decodeIfPresent(String.self, forKey: .format),
            items: try container.decodeIfPresent(JournalRecordNestedFieldDefinition.self, forKey: .items),
            objectFields: try container.decodeIfPresent([String: JournalRecordNestedFieldDefinition].self, forKey: .objectFields)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(isRequired, forKey: .isRequired)
        try container.encode(trim, forKey: .trim)
        try container.encode(nonEmpty, forKey: .nonEmpty)
        try container.encodeIfPresent(values, forKey: .values)
        try container.encodeIfPresent(minimum, forKey: .minimum)
        try container.encodeIfPresent(maximum, forKey: .maximum)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encodeIfPresent(items, forKey: .items)
        try container.encodeIfPresent(objectFields, forKey: .objectFields)
    }
}

public struct JournalRecordDefinition: Codable, Equatable, Sendable {
    public let recordType: String
    public let fields: [String: JournalRecordFieldDefinition]

    public init(recordType: String, fields: [String: JournalRecordFieldDefinition]) {
        self.recordType = recordType
        self.fields = fields
    }
}

public struct JournalRecordIntegerRange: Codable, Equatable, Sendable {
    public let minimum: Int64
    public let maximum: Int64

    public init(minimum: Int64, maximum: Int64) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public static let jsonSafe = JournalRecordIntegerRange(
        minimum: -9_007_199_254_740_991,
        maximum: 9_007_199_254_740_991
    )
}

public struct JournalRecordContractDocument: Codable, Equatable, Sendable {
    public let version: Int
    public let formats: [String: String]
    public let integerRange: JournalRecordIntegerRange
    public let records: [String: JournalRecordDefinition]

    public init(
        version: Int,
        formats: [String: String] = [:],
        integerRange: JournalRecordIntegerRange = .jsonSafe,
        records: [String: JournalRecordDefinition]
    ) {
        self.version = version
        self.formats = formats
        self.integerRange = integerRange
        self.records = records
    }
}

enum JournalRecordDateFormat: String, Sendable {
    case utcIso8601OptionalFraction
}

enum JournalISO8601Codec {
    private static let utcIso8601OptionalFractionPattern = "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{1,3})?Z$"

    static func date(
        from value: String,
        format: String = JournalRecordDateFormat.utcIso8601OptionalFraction.rawValue
    ) -> Date? {
        guard let format = JournalRecordDateFormat(rawValue: format) else { return nil }
        switch format {
        case .utcIso8601OptionalFraction:
            guard value.range(of: Self.utcIso8601OptionalFractionPattern, options: .regularExpression) != nil else {
                return nil
            }
            let formatter = ISO8601DateFormatter()
            if value.contains(".") {
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            } else {
                formatter.formatOptions = [.withInternetDateTime]
            }
            return formatter.date(from: value)
        }
    }

    static func string(from date: Date) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let value = fractional.string(from: date)
        return value.replacingOccurrences(of: ".000Z", with: "Z")
    }
}

public enum JournalRecordContractError: Error, Equatable, Sendable {
    case missingField(kind: JournalRecordKind, field: String)
    case unknownField(kind: JournalRecordKind, field: String)
    case invalidField(kind: JournalRecordKind, field: String)
    case unsupportedKind(String)
    case malformedResource(String)
}

public enum JournalRecordContract {
    public static let version = 1

    public static func load() throws -> JournalRecordContractDocument {
        let data = try resource(named: "contract-v1")
        do {
            let document = try JSONDecoder().decode(JournalRecordContractDocument.self, from: data)
            guard document.version == version else {
                throw JournalRecordContractError.malformedResource("unsupported contract version")
            }
            return document
        } catch let error as JournalRecordContractError {
            throw error
        } catch {
            throw JournalRecordContractError.malformedResource(error.localizedDescription)
        }
    }

    public static func recordType(for kind: JournalRecordKind) throws -> String {
        guard let definition = try load().records[kind.rawValue] else {
            throw JournalRecordContractError.unsupportedKind(kind.rawValue)
        }
        return definition.recordType
    }

    static func resource(named name: String) throws -> Data {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw JournalRecordContractError.malformedResource("missing JournalContract/\(name).json")
        }
        return try Data(contentsOf: url)
    }
}

public struct JournalContractFixture {
    public let id: String
    public let kind: JournalRecordKind
    public let payload: Data
    public let expectedNormalized: Data

    public init(id: String, kind: JournalRecordKind, payload: Data, expectedNormalized: Data) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.expectedNormalized = expectedNormalized
    }
}

public struct JournalContractFixtureSuite {
    public let version: Int
    public let valid: [JournalContractFixture]
    public let invalid: [JournalContractFixture]

    public init(version: Int, valid: [JournalContractFixture], invalid: [JournalContractFixture]) {
        self.version = version
        self.valid = valid
        self.invalid = invalid
    }
}

public enum JournalContractFixtures {
    public static func load() throws -> JournalContractFixtureSuite {
        let data = try JournalRecordContract.resource(named: "fixtures-v1")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? Int else {
            throw JournalRecordContractError.malformedResource("invalid fixture root")
        }

        func decodeFixtures(_ key: String) throws -> [JournalContractFixture] {
            guard let values = root[key] as? [[String: Any]] else {
                throw JournalRecordContractError.malformedResource("missing fixture list \(key)")
            }
            return try values.map { value in
                guard let id = value["id"] as? String,
                      let kindRaw = value["kind"] as? String,
                      let kind = JournalRecordKind(rawValue: kindRaw),
                      let payloadObject = value["payload"] as? [String: Any],
                      JSONSerialization.isValidJSONObject(payloadObject) else {
                    throw JournalRecordContractError.malformedResource("invalid \(key) fixture")
                }
                guard key != "valid" || value["expectedNormalized"] != nil else {
                    throw JournalRecordContractError.malformedResource("missing normalization for \(id)")
                }
                let expectedObject = (value["expectedNormalized"] as? [String: Any]) ?? payloadObject
                guard JSONSerialization.isValidJSONObject(expectedObject) else {
                    throw JournalRecordContractError.malformedResource("invalid \(key) fixture normalization")
                }
                return JournalContractFixture(
                    id: id,
                    kind: kind,
                    payload: try JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys]),
                    expectedNormalized: try JSONSerialization.data(withJSONObject: expectedObject, options: [.sortedKeys])
                )
            }
        }

        return JournalContractFixtureSuite(
            version: version,
            valid: try decodeFixtures("valid"),
            invalid: try decodeFixtures("invalid")
        )
    }
}

public enum JournalRecordContractDecoder {
    public static func decode(
        _ payload: Data,
        kind: JournalRecordKind,
        contract: JournalRecordContractDocument? = nil
    ) throws -> JournalEntity {
        let document = try contract ?? JournalRecordContract.load()
        guard let definition = document.records[kind.rawValue] else {
            throw JournalRecordContractError.unsupportedKind(kind.rawValue)
        }
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw JournalRecordContractError.invalidField(kind: kind, field: "payload")
        }

        let fields = Set(object.keys)
        for (name, definition) in definition.fields {
            if definition.isRequired && object[name] == nil {
                throw JournalRecordContractError.missingField(kind: kind, field: name)
            }
            guard let value = object[name] else { continue }
            try validate(
                value,
                field: name,
                definition: definition,
                kind: kind,
                document: document
            )
        }
        for name in fields where definition.fields[name] == nil {
            throw JournalRecordContractError.unknownField(kind: kind, field: name)
        }

        var normalized = object
        normalize(&normalized, fields: definition.fields)
        try validateCrossFieldRules(normalized, kind: kind, document: document)
        let normalizedData = try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
        do {
            return try decodeEntity(normalizedData, kind: kind)
        } catch let error as JournalRecordContractError {
            throw error
        } catch {
            throw JournalRecordContractError.invalidField(kind: kind, field: "payload")
        }
    }

    private static func validate(
        _ value: Any,
        field: String,
        definition: JournalRecordFieldDefinition,
        kind: JournalRecordKind,
        document: JournalRecordContractDocument
    ) throws {
        if value is NSNull {
            if definition.isRequired { throw invalid(kind, field) }
            return
        }
        try validateValue(
            value,
            field: field,
            type: definition.type,
            required: definition.isRequired,
            nonEmpty: definition.nonEmpty,
            values: definition.values,
            minimum: definition.minimum,
            maximum: definition.maximum,
            format: nil,
            items: definition.items,
            objectFields: definition.objectFields,
            variants: definition.variants,
            variantFields: definition.variantFields,
            kind: kind,
            document: document
        )
    }

    private static func validateValue(
        _ value: Any,
        field: String,
        type: String,
        required: Bool,
        nonEmpty: Bool,
        values: [String]?,
        minimum: Int?,
        maximum: Int?,
        format: String?,
        items: JournalRecordNestedFieldDefinition?,
        objectFields: [String: JournalRecordNestedFieldDefinition]?,
        variants: [String]?,
        variantFields: [String: [String: JournalRecordNestedFieldDefinition]]?,
        kind: JournalRecordKind,
        document: JournalRecordContractDocument
    ) throws {
        if value is NSNull {
            if required { throw invalid(kind, field) }
            return
        }
        switch type {
        case "uuid":
            guard value is String, UUID(uuidString: value as? String ?? "") != nil else { throw invalid(kind, field) }
        case "date":
            guard let string = value as? String, parseDate(string, document: document, format: format) != nil else { throw invalid(kind, field) }
        case "url":
            guard let string = value as? String,
                  let url = URL(string: string),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host?.isEmpty == false else { throw invalid(kind, field) }
        case "string":
            guard let string = value as? String else { throw invalid(kind, field) }
            if nonEmpty && string.trimmedForJournal.isEmpty { throw invalid(kind, field) }
        case "enum":
            guard let string = value as? String, values?.contains(string) == true else { throw invalid(kind, field) }
        case "integer":
            guard let number = value as? NSNumber,
                  let integer = exactJSONInteger(number, range: document.integerRange) else { throw invalid(kind, field) }
            if let minimum, integer < Decimal(minimum) { throw invalid(kind, field) }
            if let maximum, integer > Decimal(maximum) { throw invalid(kind, field) }
        case "boolean":
            guard let number = value as? NSNumber, isJSONBoolean(number) else { throw invalid(kind, field) }
        case "stringArray":
            guard let items = value as? [Any], items.allSatisfy({ $0 is String }) else { throw invalid(kind, field) }
        case "uuidArray":
            guard let items = value as? [Any], items.allSatisfy({ item in
                guard let string = item as? String else { return false }
                return UUID(uuidString: string) != nil
            }) else { throw invalid(kind, field) }
        case "integerArray":
            guard let items = value as? [Any], items.allSatisfy({ item in
                guard let number = item as? NSNumber else { return false }
                return exactJSONInteger(number, range: document.integerRange) != nil
            }) else { throw invalid(kind, field) }
        case "array":
            guard let values = value as? [Any], let items else { throw invalid(kind, field) }
            for (index, item) in values.enumerated() {
                try validateNestedValue(item, field: "\(field)[\(index)]", definition: items, kind: kind, document: document)
            }
        case "object":
            guard let object = value as? [String: Any], let objectFields else { throw invalid(kind, field) }
            try validateObject(object, field: field, fields: objectFields, kind: kind, document: document)
        case "taggedUnion":
            guard let object = value as? [String: Any],
                  object.count == 1,
                  let tag = object.keys.first,
                  variants?.contains(tag) == true,
                  let inner = object[tag] as? [String: Any] else { throw invalid(kind, field) }
            if let fields = variantFields?[tag] {
                try validateObject(inner, field: "\(field).\(tag)", fields: fields, kind: kind, document: document)
            }
        case "uuidEnumMap":
            try validatePairs(value, field: field, valueType: "enum", values: values, kind: kind)
        case "uuidStringMap":
            try validatePairs(value, field: field, valueType: "string", values: nil, kind: kind)
        case "stringArrayDictionary":
            guard let dictionary = value as? [String: Any], dictionary.values.allSatisfy({ item in
                guard let values = item as? [Any] else { return false }
                return values.allSatisfy { $0 is String }
            }) else { throw invalid(kind, field) }
        case "json":
            guard JSONSerialization.isValidJSONObject(value) else { throw invalid(kind, field) }
        default:
            throw invalid(kind, field)
        }
    }

    private static func validateObject(
        _ object: [String: Any],
        field: String,
        fields: [String: JournalRecordNestedFieldDefinition],
        kind: JournalRecordKind,
        document: JournalRecordContractDocument
    ) throws {
        for (name, definition) in fields {
            guard let value = object[name] else {
                if definition.isRequired { throw invalid(kind, "\(field).\(name)") }
                continue
            }
            try validateValue(
                value,
                field: "\(field).\(name)",
                type: definition.type,
                required: definition.isRequired,
                nonEmpty: definition.nonEmpty,
                values: definition.values,
                minimum: definition.minimum,
                maximum: definition.maximum,
                format: definition.format,
                items: definition.items,
                objectFields: definition.objectFields,
                variants: nil,
                variantFields: nil,
                kind: kind,
                document: document
            )
        }
        for name in object.keys where fields[name] == nil { throw unknown(kind, "\(field).\(name)") }
    }

    private static func validateNestedValue(
        _ value: Any,
        field: String,
        definition: JournalRecordNestedFieldDefinition,
        kind: JournalRecordKind,
        document: JournalRecordContractDocument
    ) throws {
        try validateValue(
            value,
            field: field,
            type: definition.type,
            required: definition.isRequired,
            nonEmpty: definition.nonEmpty,
            values: definition.values,
            minimum: definition.minimum,
            maximum: definition.maximum,
            format: definition.format,
            items: definition.items,
            objectFields: definition.objectFields,
            variants: nil,
            variantFields: nil,
            kind: kind,
            document: document
        )
    }

    private static func validatePairs(
        _ value: Any,
        field: String,
        valueType: String,
        values: [String]?,
        kind: JournalRecordKind
    ) throws {
        guard let items = value as? [Any], items.count.isMultiple(of: 2) else { throw invalid(kind, field) }
        var keys = Set<String>()
        for index in stride(from: 0, to: items.count, by: 2) {
            guard let key = items[index] as? String, !keys.contains(key) else { throw invalid(kind, field) }
            keys.insert(key)
            guard let string = items[index + 1] as? String else { throw invalid(kind, field) }
            if valueType == "enum" && values?.contains(string) != true { throw invalid(kind, field) }
            guard UUID(uuidString: key) != nil else { throw invalid(kind, field) }
        }
    }

    private static func invalid(_ kind: JournalRecordKind, _ field: String) -> JournalRecordContractError {
        .invalidField(kind: kind, field: field)
    }

    private static func unknown(_ kind: JournalRecordKind, _ field: String) -> JournalRecordContractError {
        .unknownField(kind: kind, field: field)
    }

    private static func normalize(
        _ object: inout [String: Any],
        fields: [String: JournalRecordFieldDefinition]
    ) {
        for (name, definition) in fields {
            guard let value = object[name] else { continue }
            if definition.trim, let string = value as? String {
                object[name] = string.trimmedForJournal
            } else if definition.trim, let values = value as? [Any] {
                object[name] = values.map { ($0 as? String)?.trimmedForJournal ?? $0 }
            }
            if definition.sort == "ascending", let values = object[name] as? [Any] {
                object[name] = values.sorted {
                    (($0 as? NSNumber)?.intValue ?? 0) < (($1 as? NSNumber)?.intValue ?? 0)
                }
            }
            if definition.type == "object",
               let nested = definition.objectFields,
               var nestedObject = value as? [String: Any] {
                normalizeObject(&nestedObject, fields: nested)
                object[name] = nestedObject
            } else if definition.type == "taggedUnion",
                      let variants = definition.variantFields,
                      var union = value as? [String: Any],
                      let tag = union.keys.first,
                      var inner = union[tag] as? [String: Any],
                      let nested = variants[tag] {
                normalizeObject(&inner, fields: nested)
                union[tag] = inner
                object[name] = union
            }
        }
    }

    private static func normalizeObject(
        _ object: inout [String: Any],
        fields: [String: JournalRecordNestedFieldDefinition]
    ) {
        for (name, definition) in fields {
            guard let value = object[name] else { continue }
            if definition.trim, let string = value as? String {
                object[name] = string.trimmedForJournal
            } else if definition.trim, let values = value as? [Any] {
                object[name] = values.map { ($0 as? String)?.trimmedForJournal ?? $0 }
            }
        }
    }

    private static func validateCrossFieldRules(
        _ object: [String: Any],
        kind: JournalRecordKind,
        document: JournalRecordContractDocument
    ) throws {
        func date(_ name: String) -> Date? {
            parseDate(object[name] as? String ?? "", document: document, format: nil)
        }
        func integer(_ name: String) -> Int? {
            (object[name] as? NSNumber)?.intValue
        }
        func invalid(_ field: String) -> JournalRecordContractError {
            .invalidField(kind: kind, field: field)
        }

        switch kind {
        case .session:
            guard let start = date("startedAt"), let end = date("endedAt"), end >= start else {
                throw invalid("endedAt")
            }
        case .review:
            guard let start = date("periodStart"), let end = date("periodEnd"), end >= start else {
                throw invalid("periodEnd")
            }
            if object["scope"] as? String == ReviewScope.stage.rawValue {
                guard object["projectId"] != nil, object["phaseId"] != nil else {
                    throw invalid("phaseId")
                }
            }
        case .evidenceContract:
            guard let trigger = object["trigger"] as? [String: Any], trigger.count == 1 else {
                throw invalid("trigger")
            }
            if let interval = trigger["interval"] as? [String: Any],
               let days = (interval["days"] as? NSNumber)?.intValue {
                guard days > 0 else { throw invalid("trigger") }
            } else if let milestone = trigger["milestone"] as? [String: Any],
                      let value = milestone["_0"] as? String {
                guard !value.trimmedForJournal.isEmpty else { throw invalid("trigger") }
            } else {
                throw invalid("trigger")
            }
        case .coursePlan:
            guard let start = date("startsOn"),
                  object["deadline"] == nil || (date("deadline").map { $0 >= start } ?? false) else {
                throw invalid("deadline")
            }
        case .planPhase:
            guard let start = date("targetStart"), let end = date("targetEnd"), end >= start else {
                throw invalid("targetEnd")
            }
        case .plannedSession:
            if let window = object["planningWindow"] as? [String: Any] {
                let start = parseDate(window["start"] as? String ?? "", document: document, format: nil)
                let end = parseDate(window["end"] as? String ?? "", document: document, format: nil)
                guard let start, let end, end >= start else {
                    throw invalid("planningWindow.end")
                }
            }
        case .availabilityRule:
            guard let start = integer("startMinute"),
                  let end = integer("endMinute"),
                  end > start,
                  let minimum = integer("minimumSessionMinutes"),
                  end - start >= minimum else {
                throw invalid("endMinute")
            }
            if object["validFrom"] != nil, object["validThrough"] != nil,
               let from = date("validFrom"), let through = date("validThrough"), from > through {
                throw invalid("validThrough")
            }
        case .practiceRoutine:
            guard let weekdays = object["weekdays"] as? [Any],
                  !weekdays.isEmpty,
                  weekdays.allSatisfy({ (1...7).contains(($0 as? NSNumber)?.intValue ?? 0) }) else {
                throw invalid("weekdays")
            }
            if let blocks = object["blocks"] as? [Any] {
                var blockIDs = Set<String>()
                var ordinals = Set<Int>()
                for value in blocks {
                    guard let block = value as? [String: Any],
                          let blockID = block["id"] as? String,
                          let ordinal = (block["ordinal"] as? NSNumber)?.intValue,
                          blockIDs.insert(blockID).inserted,
                          ordinals.insert(ordinal).inserted else {
                        throw invalid("blocks")
                    }
                }
                guard ordinals.sorted() == Array(0..<blocks.count) else { throw invalid("blocks") }
            }
            if let reminder = object["reminderTime"] as? [String: Any] {
                guard (0...23).contains((reminder["hour"] as? NSNumber)?.intValue ?? -1),
                      (0...59).contains((reminder["minute"] as? NSNumber)?.intValue ?? -1) else {
                    throw invalid("reminderTime")
                }
            }
        case .practiceSession:
            guard let start = date("startedAt"), let end = date("endedAt"), end >= start,
                  let active = integer("activeDurationSeconds"),
                  Double(active) <= end.timeIntervalSince(start) + 1 else {
                throw invalid("activeDurationSeconds")
            }
            var segmentVisits: [String: Int] = [:]
            var segmentActiveTotal = 0
            if let segments = object["segments"] as? [Any] {
                for value in segments {
                    guard let segment = value as? [String: Any],
                          let blockID = segment["blockID"] as? String,
                          let segmentStart = parseDate(segment["startedAt"] as? String ?? "", document: document, format: nil),
                          let segmentEnd = parseDate(segment["endedAt"] as? String ?? "", document: document, format: nil),
                          let segmentActive = (segment["activeDurationSeconds"] as? NSNumber)?.intValue,
                          let isPause = segment["isPause"] as? Bool,
                          segmentEnd >= segmentStart,
                          segmentActive >= 0,
                          Double(segmentActive) <= segmentEnd.timeIntervalSince(segmentStart) + 1,
                          !isPause || segmentActive == 0 else {
                        throw invalid("segments")
                    }
                    guard !isPause, segmentActive > 0 else { continue }
                    segmentVisits[blockID, default: 0] += 1
                    segmentActiveTotal += segmentActive
                }
                guard segmentActiveTotal == active else { throw invalid("segments") }
            }
            if let summary = object["summary"] as? [String: Any] {
                guard let total = (summary["totalActiveDurationSeconds"] as? NSNumber)?.intValue,
                      total >= 0,
                      total == active,
                      let summaries = summary["blockSummaries"] as? [Any] else {
                    throw invalid("summary")
                }
                var summaryIDs = Set<String>()
                var summaryTotal = 0
                for value in summaries {
                    guard let block = value as? [String: Any],
                          let blockID = block["blockID"] as? String,
                          summaryIDs.insert(blockID).inserted,
                          let target = (block["targetMinutes"] as? NSNumber)?.intValue,
                          let blockActive = (block["activeDurationSeconds"] as? NSNumber)?.intValue,
                          let visits = (block["visitCount"] as? NSNumber)?.intValue,
                          let wasSkipped = block["wasSkipped"] as? Bool,
                          let wasExtended = block["wasExtended"] as? Bool,
                          target > 0,
                          blockActive >= 0,
                          visits >= 0,
                          wasSkipped == (blockActive == 0),
                          wasExtended == (blockActive > target * 60) else {
                        throw invalid("summary.blockSummaries")
                    }
                    summaryTotal += blockActive
                    if let expectedVisits = segmentVisits[blockID] {
                        guard visits == expectedVisits, blockActive > 0 else {
                            throw invalid("summary.blockSummaries")
                        }
                    } else {
                        guard blockActive == 0, visits == 0 else {
                            throw invalid("summary.blockSummaries")
                        }
                    }
                }
                guard summaryTotal == total,
                      Set(segmentVisits.keys).isSubset(of: summaryIDs) else {
                    throw invalid("summary")
                }
            }
        case .reviewDecision:
            guard let decision = object["kind"] as? String else { throw invalid("kind") }
            if decision == "changeNextStep" {
                guard let value = object["nextStep"] as? String, !value.trimmedForJournal.isEmpty else {
                    throw invalid("nextStep")
                }
            }
            if ["reviseContract", "changeFrequency"].contains(decision), object["contractId"] == nil {
                throw invalid("contractId")
            }
            if decision == "complete", object["capstoneProofId"] == nil {
                throw invalid("capstoneProofId")
            }
            if decision == "advancePhase" {
                guard object["phaseId"] != nil else { throw invalid("phaseId") }
                guard object["qualifyingProofAcceptanceId"] != nil else {
                    throw invalid("qualifyingProofAcceptanceId")
                }
            }
            if ["extendPhase", "revisePhase"].contains(decision), object["phaseId"] == nil {
                throw invalid("phaseId")
            }
        default:
            break
        }
    }

    private static func decodeEntity(_ payload: Data, kind: JournalRecordKind) throws -> JournalEntity {
        let decoder = JSONDecoder.journal
        switch kind {
        case .project: return .project(try decoder.decode(Project.self, from: payload))
        case .session: return .session(try decoder.decode(LearningSession.self, from: payload))
        case .proof: return .proof(try decoder.decode(Proof.self, from: payload))
        case .review: return .review(try decoder.decode(Review.self, from: payload))
        case .evidenceContract: return .evidenceContract(try decoder.decode(EvidenceContract.self, from: payload))
        case .evidenceAcceptance: return .evidenceAcceptance(try decoder.decode(EvidenceAcceptance.self, from: payload))
        case .proofRevision: return .proofRevision(try decoder.decode(ProofRevision.self, from: payload))
        case .reviewDecision: return .reviewDecision(try decoder.decode(ReviewDecision.self, from: payload))
        case .trailEvent: return .trailEvent(try decoder.decode(TrailEvent.self, from: payload))
        case .coursePlan: return .coursePlan(try decoder.decode(CoursePlan.self, from: payload))
        case .planPhase: return .planPhase(try decoder.decode(PlanPhase.self, from: payload))
        case .plannedSession: return .plannedSession(try decoder.decode(PlannedSession.self, from: payload))
        case .availabilityRule: return .availabilityRule(try decoder.decode(AvailabilityRule.self, from: payload))
        case .schedulingPreferences: return .schedulingPreferences(try decoder.decode(SchedulingPreferences.self, from: payload))
        case .practiceRoutine:
            let value = try decoder.decode(PracticeRoutine.self, from: payload)
            return .practiceRoutine(try value.validated(requireProject: false))
        case .practiceSession:
            let value = try decoder.decode(PracticeSession.self, from: payload)
            return .practiceSession(try value.validated())
        }
    }

    private static func parseDate(
        _ value: String,
        document: JournalRecordContractDocument,
        format: String?
    ) -> Date? {
        let formatName = format ?? "iso8601"
        guard let formatValue = document.formats[formatName] else { return nil }
        return JournalISO8601Codec.date(from: value, format: formatValue)
    }

    private static func exactJSONInteger(
        _ number: NSNumber,
        range: JournalRecordIntegerRange
    ) -> Decimal? {
        guard !isJSONBoolean(number), number.doubleValue.isFinite else { return nil }
        var value = number.decimalValue
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        guard value == rounded,
              rounded >= Decimal(range.minimum),
              rounded <= Decimal(range.maximum) else { return nil }
        return rounded
    }

    private static func isJSONBoolean(_ number: NSNumber) -> Bool {
        String(cString: number.objCType) == "c"
    }
}

public enum JournalRecordContractEncoder {
    /// Encodes only the canonical record payload, unwrapping Swift's
    /// JournalEntity associated-value envelope (`{ "project": { "_0": ... } }`).
    public static func encode(_ entity: JournalEntity) throws -> Data {
        let wrapperData = try JSONEncoder.journal.encode(entity)
        guard let wrapper = try JSONSerialization.jsonObject(with: wrapperData) as? [String: Any],
              let wrappedPayload = wrapper[entity.reference.kind.rawValue] as? [String: Any],
              var payload = wrappedPayload["_0"] as? [String: Any] else {
            throw JournalRecordContractError.invalidField(
                kind: entity.reference.kind,
                field: "payload"
            )
        }
        if let fields = try? JournalRecordContract.load().records[entity.reference.kind.rawValue]?.fields {
            for (name, definition) in fields
                where definition.sort == "ascending" {
                if let values = payload[name] as? [Any] {
                    payload[name] = values.sorted {
                        (($0 as? NSNumber)?.intValue ?? 0) < (($1 as? NSNumber)?.intValue ?? 0)
                    }
                }
            }
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}
