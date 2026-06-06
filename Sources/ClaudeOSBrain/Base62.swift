enum Base62 {
    private static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static func encode(_ value: Int) -> String {
        guard value > 0 else { return "0" }
        var n = value
        var chars: [Character] = []
        while n > 0 {
            chars.append(alphabet[n % 62])
            n /= 62
        }
        return String(chars.reversed())
    }
}
