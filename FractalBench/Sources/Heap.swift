struct MaxHeap<Element> {
    private var storage: [Element] = []
    private let areSorted: (Element, Element) -> Bool

    // areSorted(a,b) == true means a has higher priority than b.
    init(areSorted: @escaping (Element, Element) -> Bool) {
        self.areSorted = areSorted
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    func peek() -> Element? { storage.first }

    mutating func push(_ element: Element) {
        storage.append(element)
        siftUp(from: storage.count - 1)
    }

    @discardableResult
    mutating func pop() -> Element? {
        guard !storage.isEmpty else { return nil }
        if storage.count == 1 { return storage.removeLast() }
        storage.swapAt(0, storage.count - 1)
        let element = storage.removeLast()
        siftDown(from: 0)
        return element
    }

    mutating func replaceTop(with element: Element) {
        guard !storage.isEmpty else {
            storage = [element]
            return
        }
        storage[0] = element
        siftDown(from: 0)
    }

    func toArray() -> [Element] { storage }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            if areSorted(storage[child], storage[parent]) {
                storage.swapAt(child, parent)
                child = parent
            } else {
                return
            }
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var candidate = parent

            if left < storage.count, areSorted(storage[left], storage[candidate]) {
                candidate = left
            }
            if right < storage.count, areSorted(storage[right], storage[candidate]) {
                candidate = right
            }
            if candidate == parent { return }
            storage.swapAt(parent, candidate)
            parent = candidate
        }
    }
}
