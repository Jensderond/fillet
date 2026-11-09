/// How the dots' parameters read in the inspector and the MCP tool. Kept beside
/// `DotsPattern.swift` so the inspector could be fixed while that file was being worked on; the
/// pattern's owner can fold these into its declaration (`.named(…)`, `.shown(when:is:)`) and
/// delete this file.
extension DotsPattern {
    public static func presented(_ parameters: [TextureParameter]) -> [TextureParameter] {
        // The flat disc's place among the profiles, looked up so a reordered menu still matches.
        let flat = parameters.lazy.compactMap { p -> Int? in
            guard p.id == "profile", case .choice(let options) = p.kind else { return nil }
            return options.firstIndex(of: "Flat disc")
        }.first
        return parameters.map { p in
            guard p.id == "edge" else { return p }
            // Part of the flat disc's shape, so it sits under Profile and only shows for it.
            let rim = p.named("Rim rounding", help: "Rounds the disc's top edge (0 = sharp, up to about the dot's height)")
            return flat.map { rim.shown(when: "profile", is: Double($0)) } ?? rim
        }
    }

    /// With "Whole dots only" every dot stays clear of the face's borders, so a fade there has
    /// nothing to fade.
    public static func fadesAtBorders(_ values: TextureValues) -> Bool { !values.bool("whole") }
}
