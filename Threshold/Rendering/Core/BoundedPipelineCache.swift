/// Actor-owned LRU for specialized pipelines. Generic fallback pipelines live
/// separately, so evicting a specialization never removes the rendering fallback.
struct BoundedPipelineCache<Value> {
    private var values: [String: Value] = [:]
    private var recency: [String] = []
    let capacity: Int

    init(capacity: Int = 128) { self.capacity = max(1, capacity) }

    subscript(key: String) -> Value? {
        mutating get {
            guard let value = values[key] else { return nil }
            recency.removeAll { $0 == key }
            recency.append(key)
            return value
        }
        set {
            if let newValue {
                values[key] = newValue
                recency.removeAll { $0 == key }
                recency.append(key)
                while recency.count > capacity {
                    values.removeValue(forKey: recency.removeFirst())
                }
            } else {
                removeValue(forKey: key)
            }
        }
    }

    var keys: Dictionary<String, Value>.Keys { values.keys }
    var count: Int { values.count }

    @discardableResult
    mutating func removeValue(forKey key: String) -> Value? {
        recency.removeAll { $0 == key }
        return values.removeValue(forKey: key)
    }

    mutating func removeAll() {
        values.removeAll()
        recency.removeAll()
    }
}
