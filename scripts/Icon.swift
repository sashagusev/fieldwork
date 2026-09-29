import AppKit

// The app's "done" bullet: a checked circle, ink on white.
let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedWhite: 0.90, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186).fill()
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 104, y: 106, width: 816, height: 816), xRadius: 182, yRadius: 182).fill()
let ink = NSColor(calibratedRed: 0.094, green: 0.094, blue: 0.106, alpha: 1)
ink.setStroke()
let ring = NSBezierPath(ovalIn: NSRect(x: 292, y: 292, width: 440, height: 440))
ring.lineWidth = 34
ring.stroke()
let check = NSBezierPath()
check.lineWidth = 40
check.lineCapStyle = .round
check.lineJoinStyle = .round
check.move(to: NSPoint(x: 416, y: 512))
check.line(to: NSPoint(x: 488, y: 440))
check.line(to: NSPoint(x: 614, y: 586))
check.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
