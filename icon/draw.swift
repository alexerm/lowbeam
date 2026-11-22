import Cocoa
// App icon: a sun whose rays fade and shorten clockwise, half its disc lit. Light that dims around the dial.
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let inset: CGFloat = 100, r: CGFloat = 185
let tile = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset), xRadius: r, yRadius: r)
NSGradient(colors: [NSColor(red: 0.16, green: 0.15, blue: 0.15, alpha: 1), NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)])!.draw(in: tile, angle: -90)
let c = CGPoint(x: S/2, y: S/2)
let amber = NSColor(red: 0.95, green: 0.65, blue: 0.29, alpha: 1)
// glow
let glow = NSGradient(colors: [amber.withAlphaComponent(0.28), amber.withAlphaComponent(0)])!
glow.draw(fromCenter: c, radius: 0, toCenter: c, radius: 330, options: [])
// rays: 12, starting at top, going clockwise, fading
for i in 0..<12 {
    let t = CGFloat(i) / 11
    let a = CGFloat.pi/2 - CGFloat(i) * (2*CGFloat.pi/12)
    let r0: CGFloat = 200, r1: CGFloat = 200 + 110 * (1 - 0.75*t)
    ctx.setStrokeColor(amber.withAlphaComponent(1 - 0.85*t).cgColor)
    ctx.setLineWidth(34); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: c.x + r0*cos(a), y: c.y + r0*sin(a)))
    ctx.addLine(to: CGPoint(x: c.x + r1*cos(a), y: c.y + r1*sin(a)))
    ctx.strokePath()
}
// disc: ring, left half lit
let dr: CGFloat = 140
ctx.setStrokeColor(amber.cgColor); ctx.setLineWidth(30)
ctx.addEllipse(in: CGRect(x: c.x-dr, y: c.y-dr, width: 2*dr, height: 2*dr)); ctx.strokePath()
ctx.setFillColor(amber.cgColor)
ctx.move(to: c); ctx.addArc(center: c, radius: dr, startAngle: .pi/2, endAngle: 3 * .pi/2, clockwise: false); ctx.closePath(); ctx.fillPath()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
