import Foundation

struct ShortcutConfiguration: Codable, Equatable {
    static let control: UInt32 = 1
    static let option: UInt32 = 2
    static let shift: UInt32 = 4
    static let command: UInt32 = 8
    static let standard = ShortcutConfiguration(keyCode: 49, modifiers: control | shift)
    var keyCode: UInt32
    var modifiers: UInt32

    struct Key: Identifiable {
        let code: UInt32
        let title: String
        var id: UInt32 { code }
    }
    /// Punctuation keys (ANSI layout codes). Allowed with a single Command/Control modifier.
    static let punctuation: [(UInt32, String)] = [
        (41,";"),(39,"'"),(43,","),(47,"."),(44,"/"),(42,"\\"),(27,"-"),(24,"="),(33,"["),(30,"]"),(50,"`")
    ]
    static let keys: [Key] = {
        let letters: [(UInt32, String)] = [
            (0,"A"),(11,"B"),(8,"C"),(2,"D"),(14,"E"),(3,"F"),(5,"G"),(4,"H"),(34,"I"),
            (38,"J"),(40,"K"),(37,"L"),(46,"M"),(45,"N"),(31,"O"),(35,"P"),(12,"Q"),
            (15,"R"),(1,"S"),(17,"T"),(32,"U"),(9,"V"),(13,"W"),(7,"X"),(16,"Y"),(6,"Z")
        ]
        let numbers: [(UInt32, String)] = [(29,"0"),(18,"1"),(19,"2"),(20,"3"),(21,"4"),(23,"5"),(22,"6"),(26,"7"),(28,"8"),(25,"9")]
        let functionCodes: [UInt32] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        return [Key(code: 49, title: "Espaço")] + punctuation.map { Key(code: $0.0, title: $0.1) } + letters.map { Key(code: $0.0, title: $0.1) }
            + numbers.map { Key(code: $0.0, title: $0.1) }
            + functionCodes.enumerated().map { Key(code: $0.element, title: "F\($0.offset + 1)") }
    }()

    var displayName: String {
        let symbols: [(UInt32, String)] = [(Self.control,"⌃"),(Self.option,"⌥"),(Self.shift,"⇧"),(Self.command,"⌘")]
        let prefix = symbols.filter { modifiers & $0.0 != 0 }.map(\.1).joined(separator: " ")
        let key = Self.keys.first { $0.code == keyCode }?.title ?? "Tecla \(keyCode)"
        return prefix.isEmpty ? key : "\(prefix) \(key)"
    }
    var validationError: String? {
        guard Self.keys.contains(where: { $0.code == keyCode }), modifiers & ~UInt32(15) == 0 else {
            return "Escolha uma tecla e modificadores válidos."
        }
        let singleAllowed = Self.punctuation.contains { $0.0 == keyCode }
        guard modifiers & (Self.control | Self.command) != 0, modifiers.nonzeroBitCount >= 2 || singleAllowed else {
            return "Use pelo menos dois modificadores, incluindo Control ou Command (um só vale com ; , . / etc.). Recomendado: Control + Shift."
        }
        // Common application commands do not necessarily appear in the system hotkey registry.
        if modifiers == Self.command | Self.shift,
           [0,8,2,3,5,4,38,37,46,45,31,35,12,15,1,17,32,9,13,7,6].contains(keyCode) {
            return "Essa combinação é usada por comandos comuns de aplicativos. Prefira Control + Shift ou adicione outro modificador."
        }
        if modifiers == Self.command | Self.option, [8,3,4,37,46,45,31,35,12,1,9,13].contains(keyCode) {
            return "Essa combinação é usada por comandos comuns de aplicativos. Escolha outra."
        }
        if modifiers == Self.control | Self.command, [3,12,49].contains(keyCode) {
            return "Essa combinação é reservada para ações comuns do macOS. Escolha outra."
        }
        if modifiers == Self.command | Self.option | Self.shift, keyCode == 9 {
            return "Essa combinação é usada para colar sem formatação. Escolha outra."
        }
        return nil
    }
}
