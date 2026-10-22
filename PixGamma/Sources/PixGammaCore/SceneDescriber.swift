import CoreGraphics
import Foundation
import Vision

/// Builds the Recover prompt from what Vision sees in the photo. Without a subject, diffusion
/// redrew macaw feathers as folded fabric; "macaw parrot, detailed feathers" gave every barb.
/// Runs on-device (VNClassifyImageRequest), so nothing leaves the Mac.
public enum SceneDescriber {
    struct Rule {
        let labels: Set<String>
        let texture: String
        let minConfidence: Float
    }

    /// Hair is never asked for here: with "people" in a street scene, diffusion grew hair over a
    /// phone. Faces get the portrait prompt in Upscaler instead.
    /// First match names the subject; up to two matches add their texture. Scenery labels need
    /// more confidence: a printed T-shirt scored "structure" 0.45 and "rocks" 0.26.
    static let rules: [Rule] = [
        Rule(labels: ["bird", "parrot", "macaw", "owl", "eagle", "duck", "chicken", "peacock", "songbird", "raptor", "feather"],
             texture: "detailed feathers with fine barbs and shafts", minConfidence: 0.3),
        Rule(labels: ["cat", "dog", "puppy", "kitten", "mammal", "horse", "rabbit", "fox", "lion", "tiger", "bear", "fur"],
             texture: "detailed natural fur", minConfidence: 0.3),
        Rule(labels: ["clothing", "textile", "shirt", "jacket", "dress", "sweater", "hat", "headgear", "fabric", "jeans"],
             texture: "fine fabric weave and fibres", minConfidence: 0.3),
        Rule(labels: ["leather", "material", "handbag", "shoes", "footwear"],
             texture: "fine natural material grain", minConfidence: 0.12),
        Rule(labels: ["computer", "laptop", "computer_keyboard", "consumer_electronics", "cellphone", "camera", "watch", "headphones", "machine"],
             texture: "product photo, crisp edges, clean metal and plastic surfaces", minConfidence: 0.3),
        Rule(labels: ["food", "fruit", "vegetable", "dessert", "bread", "meal", "drink", "coffee"],
             texture: "appetizing detailed food texture", minConfidence: 0.3),
        Rule(labels: ["flower", "plant", "tree", "foliage", "leaf", "grass", "garden"],
             texture: "detailed leaves and petals", minConfidence: 0.3),
        Rule(labels: ["car", "vehicle", "motorcycle", "bicycle", "automobile"],
             texture: "glossy paint and crisp details", minConfidence: 0.3),
        Rule(labels: ["building", "structure", "architecture", "house", "bridge", "interior_room"],
             texture: "crisp architectural detail, brick and stone texture", minConfidence: 0.6),
        Rule(labels: ["mountain", "landscape", "rocks", "beach", "sky", "water", "desert", "forest"],
             texture: "detailed rocks, foliage and terrain", minConfidence: 0.6),
    ]

    /// Vision category names that read badly after "a".
    static let nouns = ["people": "person", "adult": "person", "teen": "person", "clothing": "garment",
                        "textile": "fabric", "material": "material sample", "consumer electronics": "electronic device",
                        "machine": "device", "headgear": "hat"]

    /// How much Recover may redraw. Diffusion invents shapes: on a trail sign it wiped the map,
    /// grew branches on it and garbled the lines Vision did not box as text.
    public enum Kind: String, Codable, Sendable {
        case organic    // feathers, fur, hair, skin, plants: free redraw
        case product    // electronics, leather, shoes, bags: texture only, shapes kept
        case graphic    // signs, documents, maps, posters, screens: barely touched
        case general
    }

    static let graphicLabels: Set<String> = ["sign", "document", "map", "poster", "text", "paper", "book", "screenshot",
                                             "menu", "receipt", "whiteboard", "billboard", "banner", "chart", "diagram",
                                             "label", "envelope", "card", "calendar", "magazine", "newspaper", "monitor", "screen"]
    static let productLabels: Set<String> = ["computer", "laptop", "computer_keyboard", "consumer_electronics", "cellphone",
                                             "camera", "watch", "headphones", "machine", "leather", "material", "handbag",
                                             "shoes", "footwear", "jewelry", "bottle", "cosmetics", "furniture", "tool"]
    static let organicLabels: Set<String> = ["bird", "parrot", "macaw", "animal", "mammal", "cat", "dog", "fur", "feather",
                                             "flower", "plant", "tree", "foliage", "people", "adult", "child", "portrait"]

    public struct Description: Sendable {
        public var prompt: String?
        public var kind: Kind
        public var labels: [String]
    }

    public static func describe(_ image: RGBAImage) -> Description {
        guard let cg = image.makeCGImage() else { return Description(prompt: nil, kind: .general, labels: []) }
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        let results = (request.results ?? []).map { ($0.identifier, $0.confidence) }
        return Description(prompt: prompt(labels: results), kind: kind(labels: results),
                           labels: results.filter { $0.1 >= 0.3 }.map(\.0))
    }

    /// Graphic wins over everything: a person holding a phone in front of a map is still a map
    /// to diffusion. Then product, then organic.
    static func kind(labels results: [(String, Float)]) -> Kind {
        func has(_ set: Set<String>, _ min: Float) -> Bool { results.contains { set.contains($0.0) && $0.1 >= min } }
        if has(graphicLabels, 0.3) { return .graphic }
        if has(productLabels, 0.3) || has(["leather", "material"], 0.12) { return .product }
        if has(organicLabels, 0.3) { return .organic }
        return .general
    }

    /// Vision returns labels sorted by confidence, and equal scores in general-to-specific order
    /// (animal, bird, parrot), so the last of the top group is the most specific name.
    static func prompt(labels results: [(String, Float)]) -> String? {
        var subject: String?
        var textures: [String] = []
        for rule in rules where textures.count < 2 {
            let hits = results.filter { rule.labels.contains($0.0) && $0.1 >= rule.minConfidence }
            guard let best = hits.map(\.1).max() else { continue }
            if subject == nil {
                subject = hits.last { $0.1 >= best - 0.05 }?.0.replacingOccurrences(of: "_", with: " ")
            }
            textures.append(rule.texture)
        }
        guard let subject else { return nil }
        let noun = nouns[subject] ?? subject
        return "high quality photograph of a \(noun), " + textures.joined(separator: ", ") + ", sharp focus, natural light"
    }
}
