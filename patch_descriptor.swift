import Foundation

let path = "Threshold/App/FractalTypeDescriptor.swift"
var content = try! String(contentsOfFile: path)
content = content.replacingOccurrences(of: "KleinianDescriptor(),
    ]", with: "KleinianDescriptor(),
        PseudoKleinianDescriptor(),
    ]")
try! content.write(toFile: path, atomically: true, encoding: .utf8)

