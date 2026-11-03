#!/usr/bin/env swift
// 绘制应用图标并生成 AppIcon.icns
//
// 用法：swift Scripts/make-icon.swift
//
// 为什么不用 AI 生成的图：产出物会带平台水印，且纹理太碎、缩到 16px 就糊成一片。
// 这里改为矢量绘制，并且按尺寸做简化——小尺寸只保留最核心的轮廓。

import AppKit
import CoreGraphics
import Foundation

// MARK: - 配色

let bgTop = CGColor(red: 0.055, green: 0.145, blue: 0.325, alpha: 1)   // 深靛
let bgBottom = CGColor(red: 0.055, green: 0.520, blue: 0.588, alpha: 1) // 青
let paperColor = CGColor(red: 0.98, green: 0.99, blue: 1.0, alpha: 1)
let barColor = CGColor(red: 0.05, green: 0.45, blue: 0.62, alpha: 0.30)
let dropColor = CGColor(red: 0.42, green: 0.93, blue: 0.96, alpha: 0.95)

// MARK: - 绘制

func drawIcon(size s: CGFloat) -> CGImage? {
    let canvas = CGSize(width: s, height: s)
    guard let ctx = CGContext(
        data: nil, width: Int(s), height: Int(s),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let k = s / 1024.0   // 以 1024 为基准等比缩放

    // 圆角外框（外部透明，任何底色上都好看）
    let radius = 228 * k
    let frame = CGRect(x: 0, y: 0, width: s, height: s)
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()

    // 背景渐变
    let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [bgTop, bgBottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: s / 2, y: s),
        end: CGPoint(x: s / 2, y: 0),
        options: []
    )

    // 小尺寸做简化：水印条更少、不画水滴
    let barCount = s < 64 ? 2 : (s < 256 ? 3 : 4)
    let showDrop = s >= 64

    // 水滴（顶部）
    if showDrop {
        let r = 52 * k
        let cy = s * 0.835   // 再往上一点，避免水滴压住文档顶边
        ctx.saveGState()
        ctx.translateBy(x: s / 2, y: cy)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: r * 1.6))
        p.addCurve(
            to: CGPoint(x: r, y: 0),
            control1: CGPoint(x: r * 0.18, y: r * 0.78),
            control2: CGPoint(x: r, y: r * 0.46)
        )
        p.addArc(center: .zero, radius: r, startAngle: 0, endAngle: .pi, clockwise: true)
        p.addCurve(
            to: CGPoint(x: 0, y: r * 1.6),
            control1: CGPoint(x: -r, y: r * 0.46),
            control2: CGPoint(x: -r * 0.18, y: r * 0.78)
        )
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(dropColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 文档
    ctx.saveGState()
    ctx.translateBy(x: s / 2, y: s * 0.475)
    ctx.rotate(by: -8 * .pi / 180)

    let docW = 430 * k, docH = 540 * k
    let docRect = CGRect(x: -docW / 2, y: -docH / 2, width: docW, height: docH)
    let docPath = CGPath(roundedRect: docRect, cornerWidth: 26 * k, cornerHeight: 26 * k, transform: nil)

    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 34 * k,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
    ctx.addPath(docPath)
    ctx.setFillColor(paperColor)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // 文档内的斜向水印条
    ctx.saveGState()
    ctx.addPath(docPath)
    ctx.clip()
    let barW = 340 * k, barH = 30 * k
    let spacing = 118 * k
    let firstY = -docH / 2 + (s < 64 ? 120 : 105) * k
    for i in 0..<barCount {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: firstY + CGFloat(i) * spacing)
        ctx.rotate(by: -42 * .pi / 180)
        ctx.setFillColor(barColor)
        ctx.fill(CGRect(x: -barW / 2, y: -barH / 2, width: barW, height: barH))
        ctx.restoreGState()
    }
    ctx.restoreGState()
    ctx.restoreGState()

    _ = canvas
    return ctx.makeImage()
}

// MARK: - 输出 iconset

let root = FileManager.default.currentDirectoryPath
let iconset = URL(fileURLWithPath: root)
    .appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(name: String, px: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for spec in specs {
    guard let img = drawIcon(size: spec.px) else {
        FileHandle.standardError.write("绘制失败 \(spec.name)\n".data(using: .utf8)!)
        continue
    }
    let url = iconset.appendingPathComponent(spec.name)
    let rep = NSBitmapImageRep(cgImage: img)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: url)
    print("  \(spec.name)  \(spec.px)px")
}

print("==> iconset 就绪：\(iconset.path)")
