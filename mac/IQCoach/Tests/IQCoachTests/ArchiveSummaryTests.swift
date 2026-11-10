import Testing
import Foundation
@testable import IQCoach

/// The archive's fixed bins (docs/MEMORY-SPEC.md §5) against synthetic values whose exact quantiles are known.
struct ArchiveSummaryTests {
    /// A deterministic spread of values in lo...hi (a linear congruential generator, so runs are identical).
    private func values(_ n: Int, _ lo: Double, _ hi: Double, seed: UInt64 = 7) -> [Double] {
        var x = seed
        return (0..<n).map { _ in
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return lo + (hi - lo) * Double(x >> 11) / Double(1 << 53)
        }
    }

    /// The nearest-rank quantile: the ceil(q x n)-th smallest value.
    private func exact(_ v: [Double], _ q: Double) -> Double {
        let s = v.sorted()
        return s[max(1, Int((q * Double(s.count)).rounded(.up))) - 1]
    }

    private func histogram(_ v: [Double], _ bins: ArchiveBins) -> ArchiveHistogram {
        var h = ArchiveHistogram()
        for x in v { h.add(x, bins: bins) }
        return h
    }

    @Test func slotsFollowTheSpec() {
        let s = ArchiveBins.sharpness
        #expect(s.slot(50) == .bin(0))
        #expect(s.slot(49.99) == .under)
        #expect(s.slot(50 * 1.02 * 1.0001) == .bin(1))
        #expect(s.slot(10_000.1) == .over)
        let c = ArchiveBins.clipping
        #expect(c.slot(0) == .zero)
        #expect(c.slot(0.0005) == .under)
        #expect(c.slot(0.001) == .bin(0))
        #expect(c.slot(100.5) == .over)
        let t = ArchiveBins.tilt
        #expect(t.slot(-45) == .bin(0))
        #expect(t.slot(-45.01) == .under)
        #expect(t.slot(0) == .bin(180))
        #expect(t.slot(45.01) == .over)
        let n = ArchiveBins.snr
        #expect(n.slot(-0.1) == .under)
        #expect(n.slot(32.1) == .bin(128))
        #expect(n.slot(80.01) == .over)
        #expect(ArchiveBins.forMetric("clip_low_pct") == .clipping)
        #expect(ArchiveBins.forMetric("nope") == nil)
    }

    @Test func representativesAreGeometricCentresAndMidpoints() {
        #expect(abs(ArchiveBins.sharpness.representative(0) - 50 * 1.02.squareRoot()) < 1e-9)
        #expect(ArchiveBins.snr.representative(128) == 32.125)
        #expect(ArchiveBins.tilt.representative(180) == 0.125)
    }

    @Test(arguments: [0.1, 0.25, 0.5, 0.75, 0.9])
    func sharpnessQuantileIsWithinHalfABin(_ q: Double) throws {
        let v = values(1_001, 300, 4_000)
        guard case .value(let got) = histogram(v, .sharpness).quantile(q, bins: .sharpness) else { Issue.record("no value"); return }
        // Half a log bin: a factor of sqrt(1.02), about 1 % relative.
        #expect(abs(log(got / exact(v, q))) <= 0.5 * log(1.02) + 1e-12)
    }

    @Test(arguments: [0.1, 0.5, 0.9])
    func snrQuantileIsWithinAnEighthOfADecibel(_ q: Double) throws {
        let v = values(777, 12, 45, seed: 3)
        guard case .value(let got) = histogram(v, .snr).quantile(q, bins: .snr) else { Issue.record("no value"); return }
        #expect(abs(got - exact(v, q)) <= 0.125 + 1e-12)
    }

    @Test func clippingQuantilesUseTheZeroBin() throws {
        let v = Array(repeating: 0.0, count: 60) + values(40, 0.01, 30, seed: 11)
        let h = histogram(v, .clipping)
        #expect(h.zero == 60 && h.n == 100)
        #expect(h.quantile(0.5, bins: .clipping) == .value(0), "60 % of the photos clip nothing")
        guard case .value(let p90) = h.quantile(0.9, bins: .clipping) else { Issue.record("no value"); return }
        #expect(abs(log(p90 / exact(v, 0.9))) <= 0.5 * log(1.05) + 1e-12)
        var tiny = ArchiveHistogram()
        tiny.add(0.0001, bins: .clipping)
        #expect(tiny.quantile(0.5, bins: .clipping) == .below(0.001))
    }

    @Test func mergingIsExactAndOrderFree() {
        let v = values(300, 100, 5_000, seed: 5)
        let parts = [Array(v[0..<100]), Array(v[100..<180]), Array(v[180...])].map { histogram($0, .sharpness) }
        var forward = ArchiveHistogram(), backward = ArchiveHistogram()
        for p in parts { forward.merge(p) }
        for p in parts.reversed() { backward.merge(p) }
        #expect(forward == backward)
        #expect(forward == histogram(v, .sharpness))
    }

    private static let bucketJSON = #"""
        {"metrics": {"sharpness_lwph": {"counts": {"140": 3, "141": 1}, "zero": 0, "under": 1, "over": 0, "n": 5},
                     "clip_high_pct": {"counts": {"10": 2}, "zero": 3, "under": 0, "over": 0, "n": 5}},
         "shares": {"clip_high_gt1": [1, 5], "tilt_ge1": [0, 2]}}
        """#

    @Test func aBucketDecodes() throws {
        let c = try ArchiveBucketContent.decode(Data(Self.bucketJSON.utf8))
        #expect(c.metrics["sharpness_lwph"]?.counts == [140: 3, 141: 1])
        #expect(c.metrics["sharpness_lwph"]?.under == 1)
        #expect(c.metrics["clip_high_pct"]?.zero == 3)
        #expect(c.shares["clip_high_gt1"] == ShareCount(hits: 1, of: 5))
        #expect(throws: (any Error).self) { try ArchiveBucketContent.decode(Data(#"{"metrics": {"x": {"counts": {"a": 1}}}}"#.utf8)) }
    }

    // MARK: What iqa/memory.py writes

    /// Python's `Bins.slot` at values on and near bin boundaries (lo x ratio^k lands in bin k - 1 or k depending on
    /// rounding; both sides must round alike, since Swift reads the bins Python counted).
    static let pythonSlots: [(String, Double, ArchiveBins.Slot)] = [
        ("sharpness_lwph", 51.0, .bin(1)),
        ("sharpness_lwph", 199.97791114242202, .bin(70)),
        ("sharpness_lwph", 799.8232988977286, .bin(140)),
        ("sharpness_lwph", 9890.44574138017, .bin(267)),
        ("clip_high_pct", 0.0010500000000000002, .bin(1)),
        ("clip_high_pct", 0.011467399785753701, .bin(49)),
        ("clip_high_pct", 95.38614152175431, .bin(235)),
        ("snr_db", 32.1, .bin(128)),
        ("snr_db", 0.75, .bin(3)),
        ("snr_db", 80.0, .bin(320)),
        ("tilt_deg", 0.3, .bin(181)),
        ("tilt_deg", -0.05, .bin(179)),
        ("tilt_deg", 45.0, .bin(360)),
        ("tilt_deg", -45.0, .bin(0)),
        ("clip_low_pct", 0.0, .zero),
        ("clip_low_pct", 0.0009, .under),
        ("clip_low_pct", 100.0001, .over),
        ("sharpness_lwph", 812.0, .bin(140)),
        ("sharpness_lwph", 10000.0, .bin(267)),
    ]

    @Test func slotsMatchPython() throws {
        for (metric, x, slot) in Self.pythonSlots {
            #expect(try #require(ArchiveBins.forMetric(metric)).slot(x) == slot, "\(metric) \(x)")
        }
    }

    /// `Bucket.to_bytes()` (raw DEFLATE) of 403 synthetic photos folded by iqa/memory.py (random.Random(20261026)):
    /// 400 spread over each metric's usual range, 40 % of them with no blown and 60 % with no crushed pixels, plus one
    /// value under, one over and one missing per metric.
    static let pythonBucketBase64 = "jZfdbiM3DIXfZa59IepffpWiMNrESAKkTmB7u0AXefeK4qdkMnGKXtHSSBRJnXMo/1r+Ol7PT3eXZf9ruTz+cX49HS+Xw/PP10eduXv5cbqOb80ve9ktLZhJZvKy9920ZR92izg3ZsV5bDQrgmVe4tgmkhgXbGUefx5/nv3e23cfGOPfJ9Znvhdss+/B2ThwfgiMiSMQR+j7k1r2hx5PVNtsHJ2dEwWLvxgYRyzxROKJ+IvkF/GXnJ2XyC9525fILxFfwl/KWOqVKmPqlYkv4y8TV46WR05Y4sqF791PVktchXoVsfWFPAv+SvdX1OKvEFcplk/BTyW/KozZXyPziflsfmoxv5W6V/JqxNPE4lQsVrX4a+Q3UOn0BxfZcNhIUIHaF3oFalYr47tXwCa1ARtZ1x02tZn1hXFlXRuBeMGfAl3nxTMfmI+Mk50n3Z94/VHsIEX++ECAA/miPxRqb7vln+P5Zdn33H6c7o/ncR0vf/Pj1Pc43xddTufD/Z+feQvmgFwyhCS7EMVbP03hpsbQluxSkpUwGXSTFRCgKc56OtlokA2t2UgEtrJBIVuhsu1TXPWDiu0rxmZAVez0Yl6KIaLY6cVwDqyqoaEayKtxBmhVQ2Y1wlTDZbUig6ZmJWiG7WZBNFOEZsBsVoJmQSiIeu7NrkghlNZaB0ecx6ItDow7OOLgiIMjDi1w+BO4u9ZK3acQqmimoJljHg4L2iJwBgTd1M6Mdka006OdgmYOW7FwOBi0JcDhwP5APAEOh8w6NCWgTQEOR/ystTOhnX6jnRntjN9op6CdHs0UNDOimWmjmR7NTGhmQTM9mhnRzKGFxHVLO/1GOwXtDBvtDGhnQjsD2ilop6CdgnZWtHOso/4K9v9N/Lvnp9fD49PD4+H17vqZ/x9NECC8XxDzsX4UdDYhoYBCoYRCzabiKYxsmopsCiPfNBVPYTyFCN80kUgTCTQR9QfhbzaTtGkmnmaSaSaJZlJoJpFmkmgmmWYSaCaeXpLpJYFe0uglhV4ypHrdTArNpG2aiS1cdZPRBVQL7Meqn8hsKP1QP14o72jod/EVD26Lh+eXn1/h4O2Wol1ek/WjbmjV4H7+0ISpAZ8gxPq1Bsz3U9it3k+rd5PAbYHbAW6vIfiF26t30eR4gOMTon53+13kge7ktsDtsuH2hHAAwgEIJyCcgHAAwhkIByAc4XaC2xlIFyBdgHSD2x5oC9CuQLsC7QK0M9D277fuo/z3rV+fnq+H++PDRgBGlok0JU+qvouYm2SdMjbWaK4SSXasGa/APKVsalkj30q+tqfgbqjZlLOxWXMe7jTptkm6kbRMQg8nyugGoxuMlknp4V05PZYOQHtYLQVaS4XXMokt+Ya0uq/Sqo+q/qfoOCr5obIP137Ob52Vu77o9xXf7EMHPh/GlTwcdTL0yujk29u/"

    /// metric -> (q, Python's `Bucket.quantile`, the exact nearest-rank quantile of the raw values folded in).
    static let pythonQuantiles: [String: [(Double, Double, Double)]] = [
        "sharpness_lwph": [(0.1, 703.2227862271021, 705.3021630576394), (0.25, 1131.089724047425, 1139.4535724570133), (0.5, 2131.5844982758385, 2137.321200617708), (0.75, 3044.4275610542195, 3026.8995221062373), (0.9, 3638.372753924845, 3622.438523890767)],
        "snr_db": [(0.1, 15.125, 15.081439518517517), (0.25, 20.875, 20.942659027758445), (0.5, 28.125, 28.102994873991534), (0.75, 36.375, 36.475099454793316), (0.9, 41.125, 41.18573800239854)],
        "clip_high_pct": [(0.1, 0.0, 0.0), (0.25, 0.0, 0.0), (0.5, 5.769000610460028, 5.773559093117478), (0.75, 17.71962242293234, 17.665399658305237), (0.9, 24.933288200617266, 25.29737260618289)],
        "clip_low_pct": [(0.1, 0.0, 0.0), (0.25, 0.0, 0.0), (0.5, 0.0, 0.0), (0.75, 3.059424195612691, 3.034913210704061), (0.9, 5.769000610460028, 5.7679454701016)],
        "tilt_deg": [(0.1, -3.375, -3.294974963516065), (0.25, -2.125, -2.1611154180814998), (0.5, -0.125, -0.056283948705582176), (0.75, 2.375, 2.2560226300426853), (0.9, 3.375, 3.31954792816627)],
    ]
    static let pythonShares: [String: ShareCount] = ["clip_high_gt1": ShareCount(hits: 235, of: 402), "clip_low_gt1": ShareCount(hits: 139, of: 402), "tilt_ge1": ShareCount(hits: 314, of: 402)]
    static let pythonCounts: [String: Int] = ["sharpness_lwph": 402, "snr_db": 402, "clip_high_pct": 402, "clip_low_pct": 402, "tilt_deg": 402]

    @Test func aBucketPythonWroteReadsAsPythonReadsIt() throws {
        let z = try #require(Data(base64Encoded: Self.pythonBucketBase64))
        let c = try ArchiveBucketContent.decode(MemoryStore.inflate(z))
        for (metric, n) in Self.pythonCounts { #expect(c.metrics[metric]?.n == n, "\(metric)") }
        for (name, s) in Self.pythonShares { #expect(c.shares[name] == s, "\(name)") }
        for (metric, rows) in Self.pythonQuantiles {
            let bins = try #require(ArchiveBins.forMetric(metric))
            for (q, python, exact) in rows {
                let got: Double
                switch try #require(c.metrics[metric]?.quantile(q, bins: bins)) {
                case .value(let v), .below(let v), .above(let v): got = v
                }
                #expect(abs(got - python) <= 1e-9 * max(1, abs(python)), "\(metric) q\(q): Swift \(got), Python \(python)")
                // And within half a bin of the true value: a factor sqrt(ratio) for log bins, width / 2 for linear ones.
                if exact == 0 {
                    #expect(got == 0, "\(metric) q\(q)")
                } else {
                    switch bins.scale {
                    case .log(let r): #expect(abs(log(got / exact)) <= 0.5 * log(r) + 1e-12, "\(metric) q\(q)")
                    case .linear(let w): #expect(abs(got - exact) <= 0.5 * w + 1e-12, "\(metric) q\(q)")
                    }
                }
            }
        }
    }

    private func bucket(_ month: String, key: String = "m1-r30-s0", n: Int, sharp: [Int: Int] = [:], blown: (Int, Int)? = nil) -> ArchiveBucket {
        var c = ArchiveBucketContent()
        if !sharp.isEmpty { c.metrics["sharpness_lwph"] = ArchiveHistogram(counts: sharp) }
        if let blown { c.shares["clip_high_gt1"] = ShareCount(hits: blown.0, of: blown.1) }
        return ArchiveBucket(camera: "iPhone 13", month: month, analyzerKey: key, n: n, firstTS: nil, lastTS: nil, content: c)
    }

    @Test func onlyTheCurrentKeyIsMergedAndTheRestIsCounted() throws {
        let buckets = [bucket("2021-03", n: 1_000, sharp: [140: 600], blown: (210, 1_000)),
                       bucket("2026-06", n: 1_310, sharp: [140: 500, 160: 300], blown: (275, 1_310)),
                       bucket("undated", n: 0),
                       bucket("2024-01", key: "m0-r30-s0", n: 400, sharp: [10: 400], blown: (400, 400))]
        let s = try #require(ArchiveSummary.make(buckets, currentKey: "m1-r30-s0"))
        #expect(s.photos == 2_310 && s.buckets == 3)
        #expect(s.firstMonth == "2021-03" && s.lastMonth == "2026-06")
        #expect(s.leftOutPhotos == 400 && s.leftOutBuckets == 1)
        #expect(s.medianSharpness == .value(ArchiveBins.sharpness.representative(140)))
        #expect(s.blownShare == ShareCount(hits: 485, of: 2_310))
        let expected = "Earlier: \(Fmt.count(2_310, "photo")) (\(ArchiveSummary.monthText("2021-03")!) – \(ArchiveSummary.monthText("2026-06")!)), "
            + "median sharpness \(Fmt.lwph(ArchiveBins.sharpness.representative(140))), more than 1 % blown in 21 %"
        #expect(s.sentence == expected)
        #expect(s.sentence.contains("808 LW/PH"), "812 LW/PH falls in bin 140, read back at its centre")
        #expect(s.leftOutSentence == "400 earlier photos measured with another method are not included.")
        #expect(ArchiveSummary.make(buckets, currentKey: nil) == nil)
        #expect(ArchiveSummary.make(buckets, currentKey: "m9-r30-s0") == nil)
    }

    @Test func partsWithoutDataAreLeftOut() throws {
        let s = try #require(ArchiveSummary.make([bucket("2021-03", n: 3)], currentKey: "m1-r30-s0"))
        #expect(s.sentence == "Earlier: 3 photos (\(ArchiveSummary.monthText("2021-03")!))")
        let undated = try #require(ArchiveSummary.make([bucket("undated", n: 2)], currentKey: "m1-r30-s0"))
        #expect(undated.sentence == "Earlier: 2 photos")
        #expect(ArchiveSummary.monthText("2021-03")?.contains("2021") == true)
        #expect(ArchiveSummary.monthText("2021-13") == nil)
    }
}
