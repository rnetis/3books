import XCTest
@testable import RenkoTrader

final class RenkoEngineTests: XCTestCase {

    private func mk(_ rows: [(Int, Double, Double, Double, Double, Double)]) -> [Candle] {
        rows.map { Candle(t: $0.0, o: $0.1, h: $0.2, l: $0.3, c: $0.4, v: $0.5,
                          qv: 0, trades: 0, takerBuy: 0) }
    }

    func testUpRunStepsByBrickSize() {
        let t0 = 1_700_000_000_000
        var rows: [(Int, Double, Double, Double, Double, Double)] = []
        var price = 100.0
        for i in 0..<20 {
            if i % 2 == 1 { price += 0.5 }
            rows.append((t0 + i * 60_000, price, price + 0.2, price - 0.2, price, 10))
        }
        let bricks = RenkoEngine.buildBricks(candles: mk(rows), size: 0.5)
        XCTAssertGreaterThanOrEqual(bricks.count, 5)
        XCTAssertTrue(bricks.suffix(5).allSatisfy { $0.direction == 1 })
        for (a, b) in zip(bricks, bricks.dropFirst()) {
            XCTAssertEqual(b.open - a.open, 0.5, accuracy: 1e-9)
        }
    }

    func testReversalRequiresFullBrickClose() {
        let t0 = 1_700_000_000_000
        let rows: [(Int, Double, Double, Double, Double, Double)] = [
            (t0, 100.0, 101.5, 99.9, 101.4, 10),
            (t0 + 60_000, 101.4, 102.9, 101.3, 102.9, 10),
            (t0 + 120_000, 102.9, 103.0, 100.8, 100.9, 10),
        ]
        let bricks = RenkoEngine.buildBricks(candles: mk(rows), size: 1.0)
        XCTAssertEqual(bricks.map(\.direction), [1, 1, -1])
        XCTAssertEqual(bricks.last!.open, bricks.dropLast().last!.close, accuracy: 1e-9)
    }

    func testWickNeverFlipsIntraCandle() {
        let t0 = 1_700_000_000_000
        let rows: [(Int, Double, Double, Double, Double, Double)] = [
            (t0, 100.0, 101.4, 99.9, 101.4, 10),
            (t0 + 60_000, 101.4, 102.0, 101.9, 102.0, 10),
            (t0 + 120_000, 102.0, 102.3, 101.7, 102.2, 10),
        ]
        let bricks = RenkoEngine.buildBricks(candles: mk(rows), size: 1.0)
        XCTAssertTrue(bricks.allSatisfy { $0.direction == 1 })
    }

    func testRunHeadAndConsistency() {
        func brick(_ d: Int) -> Brick {
            Brick(direction: d, open: 0, close: Double(d) * 0.5, tOpen: 0, tClose: 0,
                  volume: 1, candles: 1, low: 0, high: 0)
        }
        let bricks = [brick(1), brick(1), brick(-1), brick(1), brick(1), brick(1)]
        XCTAssertEqual(RenkoEngine.runHead(bricks), 3)
        XCTAssertGreaterThanOrEqual(RenkoEngine.consistency(bricks, window: 6), 0)
        XCTAssertLessThanOrEqual(RenkoEngine.consistency(bricks, window: 6), 1)
    }

    func testSpringDetectedAndScoresLong() {
        let t0 = 1_700_000_000_000
        var rows: [(Int, Double, Double, Double, Double, Double)] = []
        var t = t0
        var price = 100.0
        for _ in 0..<6 {                                  // range 100-103
            for _ in 0..<3 {
                price += 1.0
                rows.append((t, price - 1.0, price, price - 1.2, price, 40)); t += 60_000
            }
            for _ in 0..<3 {
                price -= 1.0
                rows.append((t, price + 1.0, price + 1.2, price, price, 40)); t += 60_000
            }
        }
        price -= 2.0                                      // low-volume spring dive
        rows.append((t, price + 2.0, price + 2.0, price, price, 15)); t += 60_000
        for v in [30.0, 30.0, 35.0, 45.0] {               // reclaim + rally
            price += 1.0
            rows.append((t, price - 1.0, price + 1.0, price - 1.0, price, v)); t += 60_000
        }
        let bricks = RenkoEngine.buildBricks(candles: mk(rows), size: 1.0)
        let wyckoff = WyckoffAnalyzer.analyze(bricks)
        XCTAssertNotNil(wyckoff.shake)
        XCTAssertEqual(wyckoff.shake?.kind, "spring")
        XCTAssertFalse(wyckoff.shake!.broken)
        XCTAssertGreaterThanOrEqual(WyckoffAnalyzer.pointsFor(wyckoff, side: .long), 12)
        XCTAssertLessThanOrEqual(WyckoffAnalyzer.pointsFor(wyckoff, side: .short), 6)
    }

    func testCompositePipelineBounds() {
        let t0 = 1_700_000_000_000
        var one: [Candle] = []
        var price = 100.0
        var t = t0
        for _ in 0..<24 {
            for _ in 0..<4 {
                price += 0.5
                one.append(Candle(t: t, o: price - 0.5, h: price + 0.1, l: price - 0.6,
                                  c: price, v: 30, qv: 0, trades: 0, takerBuy: 0))
                t += 60_000
            }
            for _ in 0..<4 {
                price -= 0.5
                one.append(Candle(t: t, o: price + 0.5, h: price + 0.6, l: price - 0.1,
                                  c: price, v: 30, qv: 0, trades: 0, takerBuy: 0))
                t += 60_000
            }
        }
        let signal = SignalScorer.scan(symbol: "TEST-SWAP-USDT", k1m: one,
                                       k15m: one, tick: 0.01,
                                       settings: .default)
        XCTAssertNotNil(signal)
        XCTAssertLessThanOrEqual(signal!.scoreLong, 100)
        XCTAssertLessThanOrEqual(signal!.scoreShort, 100)
        XCTAssertEqual(signal!.breakdown.count, 4)
    }

    func testTapeStandAsideOnLifelessMarket() {
        let t0 = 1_700_000_000_000
        var rows: [(Int, Double, Double, Double, Double, Double)] = []
        for i in 0..<70 {
            rows.append((t0 + i * 60_000, 100.0, 100.05, 99.95, 100.0,
                         i < 40 ? 20.0 : 1.0))
        }
        let tape = TapeRules.evaluate(mk(rows), brickSize: 1.0)
        XCTAssertTrue(tape.standAside)
        XCTAssertLessThanOrEqual(tape.long, 25)
        XCTAssertLessThanOrEqual(tape.short, 25)
    }
}
