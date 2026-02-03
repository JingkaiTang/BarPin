import AppKit
import Foundation

let args = CommandLine.arguments
if args.count < 2 {
    fputs("Usage: make-icon.swift /path/to/AppIcon.png\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: args[1])
let size: CGFloat = 1024
let canvas = NSImage(size: NSSize(width: size, height: size))

let backgroundTop = NSColor(calibratedWhite: 0.98, alpha: 1.0)
let backgroundBottom = NSColor(calibratedWhite: 0.92, alpha: 1.0)
let pinLight = NSColor(calibratedRed: 0.98, green: 0.30, blue: 0.32, alpha: 1.0)
let pinMid = NSColor(calibratedRed: 0.90, green: 0.12, blue: 0.15, alpha: 1.0)
let pinDark = NSColor(calibratedRed: 0.62, green: 0.05, blue: 0.08, alpha: 1.0)
let highlight = NSColor(calibratedWhite: 1.0, alpha: 0.55)

canvas.lockFocus()
let backgroundRect = NSRect(x: 0, y: 0, width: size, height: size)
let rounded = NSBezierPath(roundedRect: backgroundRect, xRadius: 180, yRadius: 180)
let bgGradient = NSGradient(starting: backgroundTop, ending: backgroundBottom)
bgGradient?.draw(in: rounded, angle: -90)

let centerX: CGFloat = size / 2
let headRadius: CGFloat = 220
let headCenterY: CGFloat = 710
let headRect = NSRect(
    x: centerX - headRadius,
    y: headCenterY - headRadius,
    width: headRadius * 2,
    height: headRadius * 2
)

let neckWidth: CGFloat = 110
let neckHeight: CGFloat = 140
let neckRect = NSRect(
    x: centerX - neckWidth / 2,
    y: headCenterY - headRadius - neckHeight,
    width: neckWidth,
    height: neckHeight
)

let tipY: CGFloat = 120
let baseY: CGFloat = neckRect.minY + 10
let tip = CGPoint(x: centerX, y: tipY)
let leftBase = CGPoint(x: centerX - 140, y: baseY)
let rightBase = CGPoint(x: centerX + 140, y: baseY)

let groundShadow = NSBezierPath(ovalIn: NSRect(x: centerX - 190, y: 80, width: 380, height: 70))
NSColor(calibratedWhite: 0.0, alpha: 0.12).setFill()
groundShadow.fill()

let pinShadow = NSShadow()
pinShadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.22)
pinShadow.shadowOffset = NSSize(width: 0, height: -14)
pinShadow.shadowBlurRadius = 24

NSGraphicsContext.current?.saveGraphicsState()
pinShadow.set()

let headPath = NSBezierPath(ovalIn: headRect)
let headGradient = NSGradient(colors: [pinLight, pinMid, pinDark])
headGradient?.draw(in: headPath, angle: -120)

let neckPath = NSBezierPath(roundedRect: neckRect, xRadius: 26, yRadius: 26)
let neckGradient = NSGradient(colors: [pinLight, pinMid, pinDark])
neckGradient?.draw(in: neckPath, angle: -90)

let bodyPath = NSBezierPath()
bodyPath.move(to: leftBase)
bodyPath.line(to: rightBase)
bodyPath.line(to: tip)
bodyPath.close()
let bodyGradient = NSGradient(colors: [pinMid, pinDark])
bodyGradient?.draw(in: bodyPath, angle: -90)

NSGraphicsContext.current?.restoreGraphicsState()

let highlightOval = NSBezierPath(ovalIn: NSRect(
    x: centerX - 130,
    y: headCenterY + 20,
    width: 200,
    height: 140
))
let highlightGradient = NSGradient(colors: [highlight, NSColor(calibratedWhite: 1.0, alpha: 0.0)])
highlightGradient?.draw(in: highlightOval, angle: -45)

pinDark.setStroke()
let outline = NSBezierPath()
outline.append(headPath)
outline.append(neckPath)
outline.append(bodyPath)
outline.lineWidth = 10
outline.stroke()

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to render icon.\n", stderr)
    exit(1)
}

try png.write(to: outputURL)
