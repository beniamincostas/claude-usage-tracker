#!/usr/bin/env python3
"""Generate ClaudeUsageTracker app icon via headless WebKit rendering.
Renders the icon canvas in a headless WKWebView and exports as PNG + .icns."""

import sys, os, subprocess, tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

ICON_HTML = r'''<!DOCTYPE html>
<html><head><meta charset="UTF-8"></head>
<body>
<canvas id="c" width="1024" height="1024"></canvas>
<script>
function drawIcon(ctx, S) {
  const C = S / 2;
  const bgGrad = ctx.createRadialGradient(C, C * 0.92, 0, C, C, S * 0.72);
  bgGrad.addColorStop(0, '#2c2636');
  bgGrad.addColorStop(0.5, '#1e1a24');
  bgGrad.addColorStop(1, '#131118');
  ctx.fillStyle = bgGrad;
  ctx.fillRect(0, 0, S, S);

  ctx.globalAlpha = 0.025;
  const rng = (seed) => { let s = seed; return () => { s = (s * 16807) % 2147483647; return s / 2147483647; }; };
  const rand = rng(42);
  for (let i = 0; i < S * 8; i++) {
    ctx.fillStyle = rand() > 0.5 ? '#fff' : '#000';
    ctx.beginPath(); ctx.arc(rand() * S, rand() * S, rand() * 1.2, 0, Math.PI * 2); ctx.fill();
  }
  ctx.globalAlpha = 1;

  function lerp(a, b, t) { return a + (b - a) * t; }

  const gaugeR = S * 0.38, gaugeW = S * 0.038;
  const startAngle = Math.PI * 0.72, endAngle = Math.PI * 2.28;
  const segments = 40, segGap = 0.018;

  for (let i = 0; i < segments; i++) {
    const t = i / segments, t2 = (i + 1) / segments;
    const a1 = startAngle + t * (endAngle - startAngle) + segGap;
    const a2 = startAngle + t2 * (endAngle - startAngle) - segGap;
    let r, g, b;
    if (t < 0.35) { const p = t / 0.35; r = lerp(70,232,p); g = lerp(180,155,p); b = lerp(170,118,p); }
    else if (t < 0.7) { const p = (t-0.35)/0.35; r = lerp(232,217,p); g = lerp(155,119,p); b = lerp(118,87,p); }
    else { const p = (t-0.7)/0.3; r = lerp(217,180,p); g = lerp(119,65,p); b = lerp(87,50,p); }
    let alpha = 1;
    if (i >= segments * 0.78) alpha = 0.15 + 0.12 * Math.sin((i - segments * 0.78) * 0.5);
    ctx.globalAlpha = alpha;
    ctx.strokeStyle = `rgb(${Math.round(r)},${Math.round(g)},${Math.round(b)})`;
    ctx.lineWidth = gaugeW; ctx.lineCap = 'round';
    ctx.beginPath(); ctx.arc(C, C, gaugeR, a1, a2); ctx.stroke();
  }
  ctx.globalAlpha = 1;

  try {
    const glowGrad = ctx.createConicGradient(startAngle, C, C);
    glowGrad.addColorStop(0, 'rgba(70,180,170,0.25)');
    glowGrad.addColorStop(0.3, 'rgba(232,155,118,0.2)');
    glowGrad.addColorStop(0.6, 'rgba(217,119,87,0.15)');
    glowGrad.addColorStop(0.78, 'rgba(217,119,87,0)');
    glowGrad.addColorStop(1, 'rgba(180,65,50,0)');
    ctx.strokeStyle = glowGrad; ctx.lineWidth = gaugeW * 3; ctx.globalAlpha = 0.4;
    ctx.beginPath(); ctx.arc(C, C, gaugeR, startAngle, startAngle + (endAngle-startAngle)*0.76); ctx.stroke();
  } catch(e) {}
  ctx.globalAlpha = 1;

  ctx.strokeStyle = 'rgba(255,255,255,0.04)'; ctx.lineWidth = 1;
  ctx.beginPath(); ctx.arc(C, C, gaugeR - gaugeW * 1.2, 0, Math.PI * 2); ctx.stroke();

  const needleAngle = startAngle + 0.74 * (endAngle - startAngle);
  const nx1 = C + Math.cos(needleAngle) * S * 0.18, ny1 = C + Math.sin(needleAngle) * S * 0.18;
  const nx2 = C + Math.cos(needleAngle) * (gaugeR - gaugeW * 0.3), ny2 = C + Math.sin(needleAngle) * (gaugeR - gaugeW * 0.3);
  ctx.globalAlpha = 0.15; ctx.strokeStyle = '#E89B76'; ctx.lineWidth = S * 0.02; ctx.lineCap = 'round';
  ctx.beginPath(); ctx.moveTo(nx1, ny1); ctx.lineTo(nx2, ny2); ctx.stroke();
  ctx.globalAlpha = 1; ctx.strokeStyle = '#F0C0A0'; ctx.lineWidth = S * 0.006;
  ctx.beginPath(); ctx.moveTo(nx1, ny1); ctx.lineTo(nx2, ny2); ctx.stroke();
  ctx.fillStyle = '#fff'; ctx.globalAlpha = 0.9;
  ctx.beginPath(); ctx.arc(nx2, ny2, S * 0.009, 0, Math.PI * 2); ctx.fill();
  ctx.globalAlpha = 1;

  const hubR = S * 0.05;
  const hubGrad = ctx.createRadialGradient(C, C, 0, C, C, hubR);
  hubGrad.addColorStop(0, '#E89B76'); hubGrad.addColorStop(0.6, '#D97757'); hubGrad.addColorStop(1, '#B45037');
  ctx.fillStyle = hubGrad; ctx.beginPath(); ctx.arc(C, C, hubR, 0, Math.PI * 2); ctx.fill();
  ctx.strokeStyle = 'rgba(255,255,255,0.2)'; ctx.lineWidth = 1;
  ctx.beginPath(); ctx.arc(C, C, hubR * 0.6, 0, Math.PI * 2); ctx.stroke();

  function roundedRect(ctx, x, y, w, h, r) {
    ctx.beginPath(); ctx.moveTo(x+r, y); ctx.lineTo(x+w-r, y);
    ctx.quadraticCurveTo(x+w, y, x+w, y+r); ctx.lineTo(x+w, y+h-r);
    ctx.quadraticCurveTo(x+w, y+h, x+w-r, y+h); ctx.lineTo(x+r, y+h);
    ctx.quadraticCurveTo(x, y+h, x, y+h-r); ctx.lineTo(x, y+r);
    ctx.quadraticCurveTo(x, y, x+r, y); ctx.closePath();
  }
  const bA = { x: C - S*0.15, y: C + S*0.05, w: S*0.30, h: S*0.22 };
  const bGap = S*0.022, bW = (bA.w - bGap*2)/3;
  const bH = [0.45, 0.8, 0.62];
  const bC = [['#5CC4BA','#46B4AA'],['#E89B76','#D97757'],['#D97757','#B45037']];
  for (let i = 0; i < 3; i++) {
    const bx = bA.x + i*(bW+bGap), bh = bA.h*bH[i], by = bA.y+bA.h-bh, rad = bW*0.22;
    ctx.globalAlpha = 0.3; ctx.fillStyle = 'rgba(0,0,0,0.5)';
    roundedRect(ctx, bx+2, by+3, bW, bh, rad); ctx.fill(); ctx.globalAlpha = 1;
    const bGr = ctx.createLinearGradient(bx, by, bx, by+bh);
    bGr.addColorStop(0, bC[i][0]); bGr.addColorStop(1, bC[i][1]);
    ctx.fillStyle = bGr; roundedRect(ctx, bx, by, bW, bh, rad); ctx.fill();
    ctx.globalAlpha = 0.3;
    const hl = ctx.createLinearGradient(bx, by, bx, by+bh*0.3);
    hl.addColorStop(0, 'rgba(255,255,255,0.4)'); hl.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.fillStyle = hl; roundedRect(ctx, bx, by, bW, bh*0.3, rad); ctx.fill(); ctx.globalAlpha = 1;
  }
  ctx.strokeStyle = 'rgba(255,255,255,0.08)'; ctx.lineWidth = S*0.002;
  ctx.beginPath(); ctx.moveTo(bA.x-S*0.02, bA.y+bA.h+S*0.008);
  ctx.lineTo(bA.x+bA.w+S*0.02, bA.y+bA.h+S*0.008); ctx.stroke();

  for (let i = 0; i <= 12; i++) {
    const t = i/12, angle = startAngle + t*(endAngle-startAngle);
    const ti = gaugeR+gaugeW*0.8, to = gaugeR+gaugeW*1.4;
    ctx.strokeStyle = `rgba(255,255,255,${i<=9?0.12:0.04})`;
    ctx.lineWidth = i%3===0 ? S*0.004 : S*0.002; ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(C+Math.cos(angle)*ti, C+Math.sin(angle)*ti);
    ctx.lineTo(C+Math.cos(angle)*to, C+Math.sin(angle)*to);
    ctx.stroke();
  }

  ctx.globalAlpha = 0.06; ctx.fillStyle = '#46B4AA';
  ctx.save(); ctx.translate(C, S*0.93); ctx.rotate(Math.PI/4);
  ctx.fillRect(-S*0.012, -S*0.012, S*0.024, S*0.024);
  ctx.restore(); ctx.globalAlpha = 1;
}

const c = document.getElementById('c');
drawIcon(c.getContext('2d'), 1024);
document.title = c.toDataURL('image/png');
</script></body></html>'''


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
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1200), configuration: config)
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


def render_icon(png_path):
    """Render icon via headless WKWebView."""
    html_file = tempfile.NamedTemporaryFile(suffix='.html', mode='w', delete=False)
    html_file.write(ICON_HTML)
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
            # Filter out harmless WebKit sandbox warnings
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


def png_to_icns(png_path, icns_path):
    """Convert 1024x1024 PNG to .icns via iconutil."""
    iconset = tempfile.mkdtemp(suffix='.iconset')
    for s in [16, 32, 64, 128, 256, 512]:
        subprocess.run(['sips', '-z', str(s), str(s), png_path,
                        '--out', os.path.join(iconset, f'icon_{s}x{s}.png')],
                       capture_output=True)
        s2 = s * 2
        if s2 <= 1024:
            subprocess.run(['sips', '-z', str(s2), str(s2), png_path,
                            '--out', os.path.join(iconset, f'icon_{s}x{s}@2x.png')],
                           capture_output=True)

    subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', icns_path], check=True)
    subprocess.run(['rm', '-rf', iconset])
    print(f"   .icns written to {icns_path}")


if __name__ == '__main__':
    out_dir = sys.argv[1] if len(sys.argv) > 1 else '.'
    os.makedirs(out_dir, exist_ok=True)
    png_path = os.path.join(out_dir, 'AppIcon.png')
    icns_path = os.path.join(out_dir, 'AppIcon.icns')

    print("   Rendering icon via WebKit...")
    if not render_icon(png_path):
        print("   ERROR: Icon rendering failed.")
        print("   Open icon-design.html in a browser and click 'Download 1024x1024 PNG'")
        sys.exit(1)

    print(f"   PNG written to {png_path}")
    png_to_icns(png_path, icns_path)
