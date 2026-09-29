import AppKit
import GlyphBody

// Glyph.app — o corpo. Só desenha e percebe; nunca executa nada.

let app = NSApplication.shared
let delegate = GlyphAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
