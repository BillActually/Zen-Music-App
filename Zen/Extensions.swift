import Foundation

extension String {
    func fuzzyNormalized() -> String {
        // 1. Fold accents first (palé -> pale)
        let folded = self.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        
        // 2. Handle specific symbols
        let replacedSymbols = folded.replacingOccurrences(of: "$", with: "s")
        
        // 3. Keep only alphanumeric characters and spaces
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let cleaned = replacedSymbols.unicodeScalars
            .filter { allowed.contains($0) }
            .map { String($0) }
            .joined()
            .lowercased()
        
        // 4. Clean up extra spaces
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
