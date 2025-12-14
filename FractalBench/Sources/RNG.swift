struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextFloat01() -> Float {
        // 24-bit mantissa -> [0,1)
        let x = nextUInt64() >> 40
        return Float(x) / Float(1 << 24)
    }

    mutating func nextFloat(_ min: Float, _ max: Float) -> Float {
        min + (max - min) * nextFloat01()
    }
}
