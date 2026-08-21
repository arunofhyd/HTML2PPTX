#!/bin/bash
# =============================================================================
#  HTML to PPTX Converter — Builder & Installer
#  Built by Arun Thomas · https://github.com/arunofhyd/HTML2PPTX
#
#  This downloads the HTML2PPTX source, builds it LOCALLY on your Mac, and
#  installs it to your Applications folder. Because it's built on your own
#  machine, macOS trusts it — zero Gatekeeper warnings.
# =============================================================================

set -e

APP_NAME="HTML2PPTX"
BUNDLE_NAME="HTML2PPTX.app"
REPO_RAW="https://raw.githubusercontent.com/arunofhyd/HTML2PPTX/main"

# ---- Clean, Tasteful Orange Brand Terminal Styling -------------------------
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
ORANGE='\033[38;5;208m'; CORAL='\033[38;5;202m'; GREEN='\033[38;5;35m'; YELLOW='\033[38;5;220m'; RED='\033[38;5;196m'; GREY='\033[38;5;245m'

line() { printf "${DIM}────────────────────────────────────────────────────────────${NC}\n"; }
step() { printf "${ORANGE}${BOLD}▸${NC} ${BOLD}%s${NC}\n" "$1"; }
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$1"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$1"; }
fail() { printf "  ${RED}✗ %s${NC}\n" "$1"; }

if [ "$CI" != "true" ]; then
    clear
fi

printf "\n"
printf "${ORANGE}${BOLD}   HTML2PPTX${NC}\n"
printf "${GREY}   High-Performance 4K PowerPoint Engine for macOS${NC}\n"
printf "${GREY}   Built with ❤️ by Arun Thomas · https://github.com/arunofhyd/HTML2PPTX${NC}\n\n"
line
printf "\n"

# ---- Step 1: Command Line Tools (compiler) ---------------------------------
step "Checking build tools..."
if ! xcode-select -p >/dev/null 2>&1; then
    warn "Apple's Command Line Tools are needed to build the app."
    printf "  ${GREY}A small official Apple installer will pop up. Please click ${BOLD}Install${NC}${GREY} and wait for it to finish.${NC}\n\n"
    xcode-select --install >/dev/null 2>&1
    printf "  ${YELLOW}When the installation is COMPLETE, press [Enter] here to continue...${NC}"
    read -r
    while ! xcode-select -p >/dev/null 2>&1; do
        printf "  ${GREY}Waiting for Command Line Tools installation to finish...${NC}\n"
        sleep 5
    done
fi
ok "Swift compiler available ($(swiftc --version | head -n1))"

# ---- Step 2: Python 3 & Dependencies ---------------------------------------
step "Checking Python & PowerPoint engine..."
PYTHON_BIN=""
for p in "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3" "/usr/local/bin/python3" "/opt/homebrew/bin/python3" "/usr/bin/python3"; do
    if [ -x "$p" ]; then
        PYTHON_BIN="$p"
        break
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    PYTHON_BIN="python3"
fi

if ! $PYTHON_BIN -c "import pptx" 2>/dev/null; then
    printf "  ${GREY}Installing python-pptx library...${NC}\n"
    $PYTHON_BIN -m pip install --quiet python-pptx 2>/dev/null || pip3 install --quiet python-pptx 2>/dev/null || true
fi
ok "Python PPTX engine configured ($PYTHON_BIN)"

# ---- Step 3: Node.js & Puppeteer Engine ------------------------------------
step "Checking Headless 4K Capture engine..."
if command -v node >/dev/null 2>&1; then
    ok "Node.js detected ($(node --version))"
else
    warn "Node.js not in PATH; using bundled runtime discovery."
fi

# ---- Step 4: Workspace & Source Setup ---------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
BUILD_DIR=""

if [ -f "$SCRIPT_DIR/ConverterApp.swift" ] && [ -f "$SCRIPT_DIR/Info.plist" ]; then
    step "Building from local repository..."
    BUILD_DIR="$SCRIPT_DIR/Build"
    SRC_DIR="$SCRIPT_DIR"
else
    step "Downloading latest source code from GitHub..."
    WORK_DIR="$(mktemp -d /tmp/html2pptx_build_XXXXXX)"
    SRC_DIR="$WORK_DIR"
    BUILD_DIR="$WORK_DIR/Build"
    
    curl -fsSL "$REPO_RAW/ConverterApp.swift" -o "$SRC_DIR/ConverterApp.swift"
    curl -fsSL "$REPO_RAW/Info.plist" -o "$SRC_DIR/Info.plist"
    curl -fsSL "$REPO_RAW/converter_core.py" -o "$SRC_DIR/converter_core.py"
    curl -fsSL "$REPO_RAW/AppIcon.icns" -o "$SRC_DIR/AppIcon.icns" 2>/dev/null || true
    curl -fsSL "$REPO_RAW/AppLogo.png" -o "$SRC_DIR/AppLogo.png" 2>/dev/null || true
    curl -fsSL "$REPO_RAW/AppIcon.png" -o "$SRC_DIR/AppIcon.png" 2>/dev/null || true
    curl -fsSL "$REPO_RAW/logo.svg" -o "$SRC_DIR/logo.svg" 2>/dev/null || true
    curl -fsSL "$REPO_RAW/version.json" -o "$SRC_DIR/version.json" 2>/dev/null || true
fi

mkdir -p "$BUILD_DIR"
APP_TARGET="$BUILD_DIR/$BUNDLE_NAME"

# ---- Step 5: Native Compilation --------------------------------------------
step "Compiling Native SwiftUI Application (Apple Silicon / Intel)..."
swiftc -O -parse-as-library "$SRC_DIR/ConverterApp.swift" -o "$BUILD_DIR/HTML2PPTX"
ok "Compiled native binary HTML2PPTX"

# ---- Step 6: App Bundle Packaging ------------------------------------------
step "Packaging $BUNDLE_NAME..."
rm -rf "$APP_TARGET"
mkdir -p "$APP_TARGET/Contents/MacOS"
mkdir -p "$APP_TARGET/Contents/Resources"

# Single Source of Truth: Read version from version.json
VERSION=$(python3 -c "import json, os; p = '$SRC_DIR/version.json'; print(json.load(open(p))['version']) if os.path.exists(p) else print('1.0.2')" 2>/dev/null || echo "1.0.2")

cp "$BUILD_DIR/HTML2PPTX" "$APP_TARGET/Contents/MacOS/HTML2PPTX"
cp "$SRC_DIR/Info.plist" "$APP_TARGET/Contents/Info.plist"

# Stamp Info.plist with version from version.json
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_TARGET/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP_TARGET/Contents/Info.plist" 2>/dev/null || true

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_TARGET/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP_TARGET/Contents/Info.plist" 2>/dev/null || true

cp "$SRC_DIR/converter_core.py" "$APP_TARGET/Contents/Resources/converter_core.py"
cp "$SRC_DIR/AppIcon.icns" "$APP_TARGET/Contents/Resources/AppIcon.icns" 2>/dev/null || true
cp "$SRC_DIR/AppLogo.png" "$APP_TARGET/Contents/Resources/AppLogo.png" 2>/dev/null || true
cp "$SRC_DIR/AppIcon.png" "$APP_TARGET/Contents/Resources/AppIcon.png" 2>/dev/null || true
cp "$SRC_DIR/logo.svg" "$APP_TARGET/Contents/Resources/logo.svg" 2>/dev/null || true

chmod +x "$APP_TARGET/Contents/MacOS/HTML2PPTX"
chmod +x "$APP_TARGET/Contents/Resources/converter_core.py"
ok "App bundle v$VERSION assembled at $APP_TARGET"

# If CI mode, we stop here after creating the Build folder
if [ "$CI" = "true" ]; then
    printf "\n${GREEN}${BOLD}✓ CI Build Complete!${NC}\n\n"
    exit 0
fi

# ---- Step 7: Graphical Drag-to-Applications Window -------------------------
step "Launching interactive installation..."

INSTALLER_SWIFT="$BUILD_DIR/InstallerGUI.swift"
cat << 'EOF' > "$INSTALLER_SWIFT"
import Cocoa
import AppKit

let sourcePath = CommandLine.arguments[1]
let appName = "HTML2PPTX"

func getHighResIcon(path: String) -> NSImage {
    let iconPath = (path as NSString).appendingPathComponent("Contents/Resources/AppLogo.png")
    if FileManager.default.fileExists(atPath: iconPath), let img = NSImage(contentsOfFile: iconPath) {
        img.size = NSSize(width: 128, height: 128)
        return img
    }
    let wsIcon = NSWorkspace.shared.icon(forFile: path)
    wsIcon.size = NSSize(width: 128, height: 128)
    return wsIcon
}

func performInstallation(src: URL) -> Bool {
    let fm = FileManager.default
    let dest = URL(fileURLWithPath: "/Applications/\(src.lastPathComponent)")
    do {
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: src, to: dest)
        
        let alert = NSAlert()
        alert.messageText = "Installation Complete!"
        alert.informativeText = "\(appName) has been installed to your Applications folder."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Launch Now")
        alert.addButton(withTitle: "Done")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(dest)
        }
        NSApp.terminate(nil)
        return true
    } catch {
        let alert = NSAlert()
        alert.messageText = "Installation Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
        return false
    }
}

class DragIcon: NSImageView, NSDraggingSource {
    var fileURL: URL?
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
    override func mouseDown(with event: NSEvent) {
        guard let url = fileURL, let originalImg = image else { return }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        let drag = NSDraggingItem(pasteboardWriter: item)
        
        let dragImg = NSImage(size: bounds.size)
        dragImg.lockFocus()
        if let ctx = NSGraphicsContext.current {
            ctx.imageInterpolation = .high
        }
        originalImg.draw(in: bounds)
        dragImg.unlockFocus()
        
        drag.setDraggingFrame(bounds, contents: dragImg)
        beginDraggingSession(with: [drag], event: event, source: self)
    }
}

class DropZone: NSImageView {
    override init(frame f: NSRect) { super.init(frame: f); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let str = s.draggingPasteboard.propertyList(forType: .fileURL) as? String,
              let src = URL(string: str) else { return false }
        return performInstallation(src: src)
    }
}

class GradientArrowView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let w = bounds.width
        let h = bounds.height
        let midY = h / 2.0
        
        let stemH: CGFloat = 10
        let headH: CGFloat = 26
        let headW: CGFloat = 20
        let stemR = w - headW
        
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: midY - stemH/2))
        path.line(to: NSPoint(x: stemR, y: midY - stemH/2))
        path.line(to: NSPoint(x: stemR, y: midY - headH/2))
        path.line(to: NSPoint(x: w, y: midY))
        path.line(to: NSPoint(x: stemR, y: midY + headH/2))
        path.line(to: NSPoint(x: stemR, y: midY + stemH/2))
        path.line(to: NSPoint(x: 0, y: midY + stemH/2))
        path.close()
        
        let startColor = NSColor(red: 0.98, green: 0.45, blue: 0.09, alpha: 0.20)
        let endColor = NSColor(red: 0.98, green: 0.45, blue: 0.09, alpha: 0.85)
        let gradient = NSGradient(starting: startColor, ending: endColor)
        gradient?.draw(in: path, angle: 0)
    }
}

class OrangeInstallButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        focusRingType = .none
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(red: 0.98, green: 0.45, blue: 0.09, alpha: 1.0).cgColor
        contentTintColor = .white
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let W: CGFloat = 620, H: CGFloat = 420
let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
win.title = "Install HTML2PPTX"
win.center()

let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: W, height: H))
bg.material = .windowBackground; bg.state = .active
win.contentView = bg

let title = NSTextField(labelWithString: "Install HTML2PPTX")
title.frame = NSRect(x: 0, y: H - 65, width: W, height: 30)
title.alignment = .center
title.font = NSFont.systemFont(ofSize: 22, weight: .bold)
bg.addSubview(title)

let sub = NSTextField(labelWithString: "Drag app to Applications or click Instant Install below")
sub.frame = NSRect(x: 0, y: H - 90, width: W, height: 20)
sub.alignment = .center
sub.font = NSFont.systemFont(ofSize: 13)
sub.textColor = .secondaryLabelColor
bg.addSubview(sub)

let iconSize: CGFloat = 128
let midY: CGFloat = 150

let appIcon = DragIcon(frame: NSRect(x: 90, y: midY, width: iconSize, height: iconSize))
appIcon.imageScaling = .scaleProportionallyUpOrDown
appIcon.image = getHighResIcon(path: sourcePath)
appIcon.fileURL = URL(fileURLWithPath: sourcePath)
bg.addSubview(appIcon)

let appLabel = NSTextField(labelWithString: "HTML to PPTX")
appLabel.frame = NSRect(x: 90, y: midY - 26, width: iconSize, height: 18)
appLabel.alignment = .center
appLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
bg.addSubview(appLabel)

let arrow = GradientArrowView(frame: NSRect(x: (W - 70)/2, y: midY + iconSize/2 - 18, width: 70, height: 36))
bg.addSubview(arrow)

let drop = DropZone(frame: NSRect(x: W - 90 - iconSize, y: midY, width: iconSize, height: iconSize))
drop.imageScaling = .scaleProportionallyUpOrDown
let appsIcon = NSWorkspace.shared.icon(forFile: "/Applications")
appsIcon.size = NSSize(width: 128, height: 128)
drop.image = appsIcon
bg.addSubview(drop)

let appsLabel = NSTextField(labelWithString: "Applications")
appsLabel.frame = NSRect(x: W - 90 - iconSize, y: midY - 26, width: iconSize, height: 18)
appsLabel.alignment = .center
appsLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
bg.addSubview(appsLabel)

let btn = OrangeInstallButton(frame: NSRect(x: (W - 200)/2, y: 35, width: 200, height: 38))
btn.title = "Instant Install"
btn.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
btn.target = app
btn.action = #selector(NSApplication.performInstallClick)
bg.addSubview(btn)

class ActionHandler: NSObject {
    @objc func performInstallClick() {
        _ = performInstallation(src: URL(fileURLWithPath: sourcePath))
    }
}
let handler = ActionHandler()
btn.target = handler
btn.action = #selector(ActionHandler.performInstallClick)

win.makeKeyAndOrderFront(nil)
NSApp.activate(ignoringOtherApps: true)
app.run()
EOF

swift "$INSTALLER_SWIFT" "$APP_TARGET"

printf "\n${GREEN}${BOLD}✓ Setup Complete!${NC}\n"
printf "${GREY}Thank you for using HTML to PPTX Converter.${NC}\n\n"
