#!/usr/bin/env python3
"""Generate DMG background image — dark fiskaly theme with install instructions.
Renders via headless WKWebView (same approach as generate-icon.py)."""

import sys, os, subprocess, tempfile, struct, zlib

out_path = sys.argv[1] if len(sys.argv) > 1 else 'dmg-background.png'
version = sys.argv[2] if len(sys.argv) > 2 else '2.0.1'

# 660x480 at 1x — must match window bounds {100,100,760,580} exactly
BG_HTML = '''<!DOCTYPE html>
<html><head><meta charset="UTF-8"></head>
<body style="margin:0;padding:0;">
<canvas id="c" width="660" height="480"></canvas>
<script>
const c = document.getElementById('c');
const ctx = c.getContext('2d');
const w = 660, h = 480;

function rr(x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x+r, y); ctx.lineTo(x+w-r, y);
  ctx.quadraticCurveTo(x+w, y, x+w, y+r); ctx.lineTo(x+w, y+h-r);
  ctx.quadraticCurveTo(x+w, y+h, x+w-r, y+h); ctx.lineTo(x+r, y+h);
  ctx.quadraticCurveTo(x, y+h, x, y+h-r); ctx.lineTo(x, y+r);
  ctx.quadraticCurveTo(x, y, x+r, y); ctx.closePath();
}

// Background gradient
const bg = ctx.createLinearGradient(0, 0, 0, h);
bg.addColorStop(0, '#0C1316');
bg.addColorStop(0.5, '#111920');
bg.addColorStop(1, '#151D22');
ctx.fillStyle = bg;
ctx.fillRect(0, 0, w, h);

// Top accent line (teal, faded edges)
const accentGrad = ctx.createLinearGradient(0, 0, w, 0);
accentGrad.addColorStop(0, 'rgba(45, 212, 191, 0)');
accentGrad.addColorStop(0.25, 'rgba(45, 212, 191, 0.7)');
accentGrad.addColorStop(0.75, 'rgba(45, 212, 191, 0.7)');
accentGrad.addColorStop(1, 'rgba(45, 212, 191, 0)');
ctx.fillStyle = accentGrad;
ctx.fillRect(0, 0, w, 2);

// Header: fiskaly (left) + Claude Usage Tracker (right)
ctx.textAlign = 'left';
ctx.font = 'bold 15px -apple-system, BlinkMacSystemFont, sans-serif';
ctx.fillStyle = '#B0B8C0';
ctx.fillText('fiskaly', 24, 26);
const fW = ctx.measureText('fiskaly').width;
ctx.fillStyle = '#2DD4BF';
ctx.beginPath();
ctx.arc(24 + fW + 8, 22, 3, 0, Math.PI * 2);
ctx.fill();
ctx.textAlign = 'right';
ctx.fillStyle = '#EFF1F3';
ctx.font = 'bold 15px -apple-system, BlinkMacSystemFont, sans-serif';
ctx.fillText('Claude Usage Tracker', w - 24, 26);

// === INSTALL SECTION ===
ctx.textAlign = 'center';
ctx.fillStyle = '#2DD4BF';
ctx.font = 'bold 12px -apple-system, sans-serif';
ctx.fillText('I N S T A L L', w / 2, 52);

// Instruction above Install.command icon
ctx.fillStyle = '#EFF1F3';
ctx.font = '14px -apple-system, sans-serif';
ctx.fillText('Double-click to install', w / 2, 72);

// Down arrow indicator
ctx.fillStyle = '#8B9299';
ctx.beginPath();
ctx.moveTo(w/2, 80); ctx.lineTo(w/2 - 6, 80); ctx.lineTo(w/2, 88); ctx.lineTo(w/2 + 6, 80);
ctx.closePath(); ctx.fill();

// [Install.command icon at (330, 130)]

// "or open Terminal and paste:" hint
ctx.fillStyle = '#B0B8C0';
ctx.font = '11px -apple-system, sans-serif';
ctx.textAlign = 'center';
ctx.fillText('or open Terminal and paste:', w / 2, 200);

// Code block
const cbX = 55, cbY = 212, cbW = w - 110, cbH = 34;
rr(cbX, cbY, cbW, cbH, 6);
ctx.fillStyle = '#1A2228';
ctx.fill();
ctx.strokeStyle = '#3A4250';
ctx.lineWidth = 1;
ctx.stroke();

// "$ " prompt in teal
ctx.textAlign = 'left';
ctx.fillStyle = '#2DD4BF';
ctx.font = '12px Menlo, "SF Mono", monospace';
ctx.fillText('$', cbX + 12, cbY + 22);

// Command text
ctx.fillStyle = '#EFF1F3';
ctx.font = '11px Menlo, "SF Mono", monospace';
ctx.fillText('bash /Volumes/ClaudeUsageTracker/Install.command', cbX + 28, cbY + 22);

// === DIVIDER ===
const divY = 268;
const divGrad = ctx.createLinearGradient(60, 0, w - 60, 0);
divGrad.addColorStop(0, 'rgba(45, 53, 60, 0)');
divGrad.addColorStop(0.15, 'rgba(45, 53, 60, 0.6)');
divGrad.addColorStop(0.85, 'rgba(45, 53, 60, 0.6)');
divGrad.addColorStop(1, 'rgba(45, 53, 60, 0)');
ctx.strokeStyle = divGrad;
ctx.lineWidth = 1;
ctx.beginPath();
ctx.moveTo(60, divY);
ctx.lineTo(w - 60, divY);
ctx.stroke();

// === DRAG SECTION ===
ctx.textAlign = 'center';
ctx.fillStyle = '#B0B8C0';
ctx.font = '12px -apple-system, sans-serif';
ctx.fillText('or drag to Applications (requires admin rights)', w / 2, divY + 20);

// [App at (160, 360), Applications at (500, 360) — 64px icon: y=328-392, label ~y=392-410]

// Dashed arrow between app and Applications icons
const arrY = 360;
ctx.strokeStyle = '#4A5260';
ctx.lineWidth = 1.5;
ctx.setLineDash([6, 4]);
ctx.beginPath();
ctx.moveTo(220, arrY);
ctx.lineTo(440, arrY);
ctx.stroke();
ctx.setLineDash([]);

// Arrowhead
ctx.fillStyle = '#4A5260';
ctx.beginPath();
ctx.moveTo(448, arrY);
ctx.lineTo(438, arrY - 6);
ctx.lineTo(438, arrY + 6);
ctx.closePath();
ctx.fill();

// === FOOTER ===
ctx.fillStyle = '#8B9299';
ctx.font = '10px -apple-system, sans-serif';
ctx.textAlign = 'center';
ctx.fillText('v__VERSION__ \u00b7 macOS 13+ \u00b7 Apple Silicon', w / 2, h - 8);

document.title = c.toDataURL('image/png');
</script></body></html>'''.replace('__VERSION__', version)

# Swift WebKit renderer (reused from generate-icon.py)
SWIFT_RENDERER = '''
import Foundation
import WebKit
import AppKit

let htmlPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let html = try! String(contentsOfFile: htmlPath, encoding: .utf8)

NSApplication.shared.setActivationPolicy(.prohibited)

class Renderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let outPath: String
    var done = false

    init(html: String, outPath: String) {
        self.outPath = outPath
        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1200), configuration: config)
        super.init()
        self.webView.navigationDelegate = self
        self.webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            webView.evaluateJavaScript("document.title") { result, error in
                if let err = error { print("ERR:\\(err)"); self.done = true; return }
                guard let dataURL = result as? String,
                      dataURL.hasPrefix("data:image/png;base64,") else {
                    print("ERR:no data url"); self.done = true; return
                }
                let b64 = String(dataURL.dropFirst("data:image/png;base64,".count))
                if let data = Data(base64Encoded: b64) {
                    try! data.write(to: URL(fileURLWithPath: self.outPath))
                    print("OK:\\(data.count)")
                } else { print("ERR:base64 decode") }
                self.done = true
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("ERR:nav \\(error)"); done = true
    }
}

let r = Renderer(html: html, outPath: outPath)
var elapsed = 0.0
while !r.done && elapsed < 15 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)); elapsed += 0.1 }
if !r.done { print("ERR:timeout") }
'''


def render_bg(png_path, html_content):
    """Render background via headless WKWebView."""
    html_file = tempfile.NamedTemporaryFile(suffix='.html', mode='w', delete=False)
    html_file.write(html_content)
    html_file.close()

    swift_file = tempfile.NamedTemporaryFile(suffix='.swift', mode='w', delete=False)
    swift_file.write(SWIFT_RENDERER)
    swift_file.close()

    try:
        result = subprocess.run(
            ['swift', swift_file.name, html_file.name, png_path],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, 'DEVELOPER_DIR': '/Library/Developer/CommandLineTools'}
        )
        if result.stdout.startswith('OK:'):
            return True
        print(f"   Renderer output: {result.stdout.strip()}")
        if result.stderr:
            errors = [l for l in result.stderr.splitlines()
                      if 'sandbox' not in l.lower() and 'could not create' not in l.lower()]
            if errors:
                print(f"   Renderer errors: {errors[0]}")
        return False
    except Exception as e:
        print(f"   Renderer failed: {e}")
        return False
    finally:
        os.unlink(html_file.name)
        os.unlink(swift_file.name)


def fallback_dark_bg(png_path):
    """Minimal dark gradient PNG if WebKit rendering fails."""
    W, H = 660, 480
    raw_rows = []
    for y in range(H):
        row = bytearray([0])
        t = y / H
        r = int(12 + t * 9)
        g = int(19 + t * 10)
        b = int(22 + t * 12)
        for x in range(W):
            row.extend([r, g, b, 255])
        raw_rows.append(bytes(row))
    raw = b''.join(raw_rows)
    compressed = zlib.compress(raw, 9)
    def chunk(ctype, data):
        c = ctype + data
        crc = zlib.crc32(c) & 0xffffffff
        return struct.pack('>I', len(data)) + c + struct.pack('>I', crc)
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', compressed)
    png += chunk(b'IEND', b'')
    with open(png_path, 'wb') as f:
        f.write(png)
    print(f"   Fallback background written to {png_path}")


if __name__ == '__main__':
    print("   Rendering DMG background via WebKit...")
    if render_bg(out_path, BG_HTML):
        print(f"   Background written to {out_path}")
    else:
        print("   WebKit rendering failed, using fallback dark background")
        fallback_dark_bg(out_path)
