import Foundation
import Testing

@testable import FilletCore

@Suite("Expressions")
struct ExpressionTests {
    let ev = Evaluator.empty

    func len(_ s: String, _ e: Evaluator = .empty) throws -> Double { try e.length(Expr(s)) }

    @Test(arguments: [
        ("1 + 2 * 3", 7.0),
        ("(1 + 2) * 3", 9),
        ("2 ^ 3 ^ 2", 512),  // right associative
        ("-2 ^ 2", -4),
        ("2 ^ -1", 0.5),
        ("10 / 4", 2.5),
        ("--3", 3),
        ("+3", 3),
        (".5 + 1.25", 1.75),
        ("1e2", 100),
        ("8 - 3 - 2", 3),
        ("12 / 3 / 2", 2),
    ])
    func arithmetic(_ source: String, _ expected: Double) throws {
        #expect(try len(source) == expected)
    }

    @Test func lengthUnits() throws {
        #expect(try len("10") == 10)
        #expect(try len("10 mm") == 10)
        #expect(try len("1.5cm") == 15)
        #expect(try len("0.1 m") == 100)
        #expect(try len("1 in") == 25.4)
        #expect(try len("1 in + 1.6") == 27)  // bare number adopts mm
        #expect(try len("2 * 3 mm") == 6)
    }

    @Test func angleUnits() throws {
        #expect(try ev.angleDegrees("45") == 45)
        #expect(try ev.angleDegrees("45 deg") == 45)
        #expect(try ev.angleDegrees("90°") == 90)
        #expect(abs(try ev.angleDegrees("pi rad") - 180) < 1e-12)
        #expect(abs(try ev.angleRadians("180") - .pi) < 1e-12)
    }

    @Test func functionsAndConstants() throws {
        #expect(abs(try ev.scalar("sin(30)") - 0.5) < 1e-12)
        #expect(abs(try ev.scalar("cos(pi rad)") + 1) < 1e-12)
        #expect(abs(try ev.scalar("tan(45 deg)") - 1) < 1e-12)
        #expect(abs(try ev.angleDegrees("asin(0.5)") - 30) < 1e-9)
        #expect(abs(try ev.angleDegrees("acos(0)") - 90) < 1e-9)
        #expect(abs(try ev.angleDegrees("atan(1)") - 45) < 1e-9)
        #expect(try len("sqrt(16)") == 4)
        #expect(try len("abs(-3)") == 3)
        #expect(try len("min(4, 2, 8)") == 2)
        #expect(try len("max(4 mm, 2)") == 4)
        #expect(try len("round(2.5)") == 3)
        #expect(try len("floor(2.7)") == 2)
        #expect(try len("ceil(2.1)") == 3)
        #expect(abs(try ev.scalar("pi") - .pi) < 1e-15)
    }

    @Test func dimensionalAnalysis() throws {
        // Hypotenuse of two lengths is a length.
        #expect(try len("sqrt(3 mm * 3 mm + 4 mm * 4 mm)") == 5)
        #expect(try len("sqrt((3mm)^2 + (4mm)^2)") == 5)
        // Ratio of two lengths is unitless.
        #expect(try ev.scalar("10 mm / 2 mm") == 5)
        #expect(throws: EvalError.self) { try ev.length("5 deg") }
        #expect(throws: EvalError.self) { try ev.angleDegrees("5 mm") }
        #expect(throws: EvalError.self) { try ev.scalar("5 mm") }
        #expect(throws: EvalError.self) { try ev.length("5 mm + 3 deg") }
        #expect(throws: EvalError.self) { try ev.length("5 mm * 3 mm") }  // area is not a length
        #expect(throws: EvalError.self) { try ev.scalar("sin(3 mm)") }
        #expect(throws: EvalError.self) { try ev.length("sqrt(3 mm)") }
    }

    @Test func errorsHavePositions() {
        func error(_ s: String) -> EvalError? {
            do { _ = try ev.length(Expr(s)); return nil } catch { return error }
        }
        #expect(error("2 + foo")?.position == 4)
        #expect(error("2 + foo")?.message == "Unknown parameter 'foo'")
        #expect(error("1 / 0")?.message == "Division by zero")
        #expect(error("(1 + 2")?.message == "Missing ')'")
        #expect(error("1 +")?.message == "Unexpected end of expression")
        #expect(error("")?.message == "Expression is empty")
        #expect(error("3 apples")?.message == "Unknown unit 'apples'")
        #expect(error("3 apples")?.position == 2)
        #expect(error("2 3")?.message == "Missing operator between numbers")
        #expect(error("2 $ 3")?.position == 2)
        #expect(error("sqrt")?.message == "Function 'sqrt' needs parentheses")
        #expect(error("frobnicate(2)")?.message == "Unknown function 'frobnicate'")
        #expect(error("sqrt(1, 2)") != nil)
        #expect(error("sqrt(-1)") != nil)
        #expect(error("asin(2)") != nil)
    }

    @Test func parametersAndIdentifiers() throws {
        let e = Evaluator(values: ["width": Quantity(40, .length), "wall_2": Quantity(2)])
        #expect(try len("width/2 + 3", e) == 23)
        #expect(try len("wall_2 * 2", e) == 4)
        #expect(Expr("width/2 + wall_2 + sqrt(pi)").referencedNames == ["width", "wall_2"])
        #expect(Expr("10 mm").isLiteral)
        #expect(!Expr("width").isLiteral)
    }

    @Test func literalsAndCoding() throws {
        let a: Expr = 10
        let b: Expr = 2.5
        let c: Expr = "width / 2"
        #expect(a.source == "10")
        #expect(b.source == "2.5")
        #expect(Expr(3.0).source == "3")
        #expect(c.source == "width / 2")
        let data = try JSONEncoder().encode([a, c])
        #expect(String(decoding: data, as: UTF8.self) == #"["10","width \/ 2"]"#)
        // Numbers are accepted when decoding hand-written files.
        let decoded = try JSONDecoder().decode([Expr].self, from: Data("[12.5, \"3 mm\"]".utf8))
        #expect(decoded == ["12.5", "3 mm"])
    }

    @Test func unitSuffixAfterNamesAndParentheses() throws {
        let e = Evaluator(values: ["n": Quantity(3), "w": Quantity(10, .length)])
        #expect(try e.length("(1 + 2) cm") == 30)
        #expect(try e.length("n in") == 3 * 25.4)
        #expect(try e.length("sqrt(4) mm") == 2)
        #expect(throws: EvalError.self) { try e.length("w mm") }  // already a length
        #expect(Expr("(a + b) mm").referencedNames == ["a", "b"])
    }
}
