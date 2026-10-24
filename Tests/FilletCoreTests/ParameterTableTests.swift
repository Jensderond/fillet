import Foundation
import Testing

@testable import FilletCore

@Suite("Parameter table")
struct ParameterTableTests {
    @Test func evaluatesInDependencyOrder() throws {
        let params = [
            Parameter(name: "total", expression: "width + 2 * wall"),
            Parameter(name: "width", expression: "inner + 1 mm"),
            Parameter(name: "inner", expression: "22"),
            Parameter(name: "wall", expression: "2 mm"),
        ]
        let table = ParameterTable(params)
        #expect(table.errors.isEmpty)
        #expect(table.values["total"]?.value == 27)
        #expect(table.values["total"]?.dimension == .length)
        #expect(table.values["inner"]?.dimension == Dimension.none)
        let order = table.order.compactMap { id in params.first { $0.id == id }?.name }
        #expect(order.firstIndex(of: "inner")! < order.firstIndex(of: "width")!)
        #expect(order.firstIndex(of: "width")! < order.firstIndex(of: "total")!)
        #expect(try table.evaluator.length("total / 3") == 9)
    }

    @Test func detectsCycles() throws {
        let a = Parameter(name: "a", expression: "b + 1")
        let b = Parameter(name: "b", expression: "c * 2")
        let c = Parameter(name: "c", expression: "a")
        let d = Parameter(name: "d", expression: "5")
        let e = Parameter(name: "e", expression: "a + d")
        let table = ParameterTable([a, b, c, d, e])
        #expect(table.errors[a.id]?.message.hasPrefix("Circular reference") == true)
        #expect(table.errors[b.id]?.message.contains("a → b → c → a") == true)
        #expect(table.errors[c.id] != nil)
        #expect(table.values["d"]?.value == 5)
        #expect(table.errors[e.id]?.message == "Parameter 'a' has an error")
        #expect(throws: EvalError.self) { try table.evaluator.length("a") }
    }

    @Test func selfReferenceIsACycle() {
        let p = Parameter(name: "x", expression: "x + 1")
        #expect(ParameterTable([p]).errors[p.id]?.message == "Circular reference: x → x")
    }

    @Test func unknownNamesAndBadNames() {
        let a = Parameter(name: "a", expression: "nope * 2")
        let b = Parameter(name: "2b", expression: "1")
        let c = Parameter(name: "sqrt", expression: "1")
        let d1 = Parameter(name: "d", expression: "1")
        let d2 = Parameter(name: "d", expression: "2")
        let syntax = Parameter(name: "s", expression: "1 +")
        let table = ParameterTable([a, b, c, d1, d2, syntax])
        #expect(table.errors[a.id] == EvalError("Unknown parameter 'nope'", position: 0))
        #expect(table.errors[b.id] != nil)
        #expect(table.errors[c.id]?.message == "'sqrt' is a reserved word")
        #expect(table.errors[d1.id] == nil)
        #expect(table.errors[d2.id] != nil)
        #expect(table.values["d"]?.value == 1)
        #expect(table.errors[syntax.id] != nil)
    }

    @Test func nameValidation() {
        #expect(Parameter.validationError(forName: "width_2") == nil)
        #expect(Parameter.validationError(forName: "_x") == nil)
        #expect(Parameter.validationError(forName: "") != nil)
        #expect(Parameter.validationError(forName: "a-b") != nil)
        #expect(Parameter.validationError(forName: "mm") != nil)
        #expect(Parameter.validationError(forName: "pi") != nil)
    }
}
