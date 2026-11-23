//go:build windows

package main

import (
	"bytes"
	_ "embed"
	"fmt"
	"image"
	_ "image/png"
	"net"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/lxn/walk"
	"github.com/lxn/win"
	"golang.org/x/sys/windows"
)

//go:embed assets/logo.png
var logoPNG []byte

// Palette taken from the CK.VPN web panel.
var (
	cBG     = walk.RGB(0x0b, 0x11, 0x20)
	cCard   = walk.RGB(0x11, 0x18, 0x27)
	cBorder = walk.RGB(0x1f, 0x29, 0x37)
	cInput  = walk.RGB(0x08, 0x0c, 0x17)
	cText   = walk.RGB(0xf3, 0xf4, 0xf6)
	cMuted  = walk.RGB(0x9c, 0xa3, 0xaf)
	cPrim   = walk.RGB(0x06, 0xb6, 0xd4)
	cPrimDk = walk.RGB(0x03, 0x11, 0x16)
	cOK     = walk.RGB(0x10, 0xb9, 0x81)
	cErr    = walk.RGB(0xef, 0x44, 0x44)
	cWarn   = walk.RGB(0xf5, 0x9e, 0x0b)
)

var (
	uxtheme       = windows.NewLazySystemDLL("uxtheme.dll")
	pSetWinTheme  = uxtheme.NewProc("SetWindowTheme")
	dwmapi        = windows.NewLazySystemDLL("dwmapi.dll")
	pDwmSetWinAtt = dwmapi.NewProc("DwmSetWindowAttribute")
)

// darkControl asks Windows 10/11 to draw a native control with its dark theme.
func darkControl(w walk.Window, class string) {
	c, _ := syscall.UTF16PtrFromString(class)
	pSetWinTheme.Call(uintptr(w.Handle()), uintptr(unsafe.Pointer(c)), 0)
}

func darkTitleBar(w walk.Window) {
	v := int32(1)
	pDwmSetWinAtt.Call(uintptr(w.Handle()), 20, uintptr(unsafe.Pointer(&v)), 4) // DWMWA_USE_IMMERSIVE_DARK_MODE
}

// Brushes and fonts are cached: the status card repaints every second, and creating new GDI
// objects on each paint (and never freeing them) exhausted Windows' 10,000-object limit after a few minutes.
var (
	cacheMu sync.Mutex
	brushes = map[walk.Color]walk.Brush{}
	fonts   = map[[2]int]*walk.Font{}
)

func brush(c walk.Color) walk.Brush {
	cacheMu.Lock()
	defer cacheMu.Unlock()
	if b, ok := brushes[c]; ok {
		return b
	}
	b, _ := walk.NewSolidColorBrush(c)
	brushes[c] = b
	return b
}

func font(size int, style walk.FontStyle) *walk.Font {
	cacheMu.Lock()
	defer cacheMu.Unlock()
	k := [2]int{size, int(style)}
	if f, ok := fonts[k]; ok {
		return f
	}
	f, _ := walk.NewFont("Segoe UI", size, style)
	fonts[k] = f
	return f
}

var pGetGuiResources = windows.NewLazySystemDLL("user32.dll").NewProc("GetGuiResources")

// gdiObjects returns this process' GDI object count (limit 10,000) for the log.
func gdiObjects() int {
	h, _ := windows.GetCurrentProcess()
	n, _, _ := pGetGuiResources.Call(uintptr(h), 0) // GR_GDIOBJECTS
	return int(n)
}

func fmtBytes(n int64) string {
	u := []string{"B", "KB", "MB", "GB", "TB"}
	f, i := float64(n), 0
	for f >= 1024 && i < 4 {
		f /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%d B", n)
	}
	return fmt.Sprintf("%.1f %s", f, u[i])
}

// ---------------------------------------------------------------- flat button

type flatButton struct {
	*walk.CustomWidget
	text    string
	bg, fg  walk.Color
	enabled bool
	down    bool
	onClick func()
	fnt     *walk.Font
}

func newFlatButton(parent walk.Container, text string, bg, fg walk.Color, fnt *walk.Font, onClick func()) *flatButton {
	b := &flatButton{text: text, bg: bg, fg: fg, enabled: true, onClick: onClick, fnt: fnt}
	cw, _ := walk.NewCustomWidgetPixels(parent, 0, b.paint)
	b.CustomWidget = cw
	cw.SetCursor(walk.CursorHand())
	cw.MouseDown().Attach(func(x, y int, btn walk.MouseButton) {
		if btn == walk.LeftButton && b.enabled {
			b.down = true
			cw.Invalidate()
		}
	})
	cw.MouseUp().Attach(func(x, y int, btn walk.MouseButton) {
		was := b.down
		b.down = false
		cw.Invalidate()
		bd := cw.BoundsPixels()
		if was && b.enabled && x >= 0 && y >= 0 && x < bd.Width && y < bd.Height && b.onClick != nil {
			b.onClick()
		}
	})
	return b
}

func (b *flatButton) set(text string, bg, fg walk.Color) {
	b.text, b.bg, b.fg = text, bg, fg
	b.Invalidate()
}

func (b *flatButton) paint(c *walk.Canvas, _ walk.Rectangle) error {
	r := b.ClientBoundsPixels()
	c.FillRectanglePixels(brush(cBG), r)
	bg := b.bg
	if b.down {
		bg = walk.RGB(uint8(max(int(bg.R())-25, 0)), uint8(max(int(bg.G())-25, 0)), uint8(max(int(bg.B())-25, 0)))
	}
	fg := b.fg
	if !b.enabled {
		fg = cMuted
	}
	rad := r.Height / 3
	c.FillRoundedRectanglePixels(brush(bg), r, walk.Size{Width: rad, Height: rad})
	return c.DrawTextPixels(b.text, b.fnt, fg, r,
		walk.TextCenter|walk.TextVCenter|walk.TextSingleLine)
}

// ---------------------------------------------------------------- main window

type gui struct {
	app  *App
	mw   *walk.MainWindow
	hero *walk.CustomWidget
	conn *flatButton
	cmb  *walk.ComboBox
	logs *walk.TextEdit
	ni   *walk.NotifyIcon

	logo     *walk.Bitmap
	snap     Snapshot
	logCount int
	profiles []*Profile
	quitting bool
}

func runUI(app *App, connect string) {
	// single instance
	mtx, _ := windows.UTF16PtrFromString("Local\\CKClientSingleInstance")
	if h, err := windows.CreateMutex(nil, false, mtx); err == windows.ERROR_ALREADY_EXISTS {
		windows.CloseHandle(h)
		walk.MsgBox(nil, appName, "CK Client is already running (check the system tray).", walk.MsgBoxIconInformation)
		return
	}

	g := &gui{app: app}
	if err := g.build(); err != nil {
		walk.MsgBox(nil, appName, "UI error: "+err.Error(), walk.MsgBoxIconError)
		return
	}
	if connect != "" {
		go app.Connect(connect)
	}
	// refresh loop
	go func() {
		n := 0
		for range time.Tick(time.Second) {
			g.mw.Synchronize(g.refresh)
			if n++; n%300 == 0 { // every 5 minutes: a rising number would show a resource leak
				app.logf("GDI objects in use: %d / 10000", gdiObjects())
			}
		}
	}()
	g.mw.Run()
	app.Disconnect()
	g.ni.Dispose()
}

func (g *gui) build() error {
	mw, err := walk.NewMainWindow()
	if err != nil {
		return err
	}
	g.mw = mw
	mw.SetTitle(appName)
	mw.SetBackground(brush(cBG))
	mw.SetLayout(walk.NewVBoxLayout())
	l := mw.Layout().(*walk.BoxLayout)
	l.SetMargins(walk.Margins{HNear: 0, VNear: 0, HFar: 0, VFar: 0})
	l.SetSpacing(0)

	if img, _, err := image.Decode(bytes.NewReader(logoPNG)); err == nil {
		g.logo, _ = walk.NewBitmapFromImageForDPI(img, 96)
		if ic, err := walk.NewIconFromImageForDPI(img, 96); err == nil {
			mw.SetIcon(ic)
			if ni, err := walk.NewNotifyIcon(mw); err == nil {
				g.ni = ni
				ni.SetIcon(ic)
				ni.SetToolTip(appName)
				ni.SetVisible(true)
			}
		}
	}

	// ---- hero (logo, status card)
	g.hero, _ = walk.NewCustomWidgetPixels(mw, 0, g.paintHero)
	g.hero.SetMinMaxSize(walk.Size{Width: 440, Height: 250}, walk.Size{Width: 440, Height: 250})

	body, _ := walk.NewComposite(mw)
	body.SetBackground(brush(cBG))
	bl := walk.NewVBoxLayout()
	bl.SetMargins(walk.Margins{HNear: 16, VNear: 0, HFar: 16, VFar: 14})
	bl.SetSpacing(10)
	body.SetLayout(bl)

	// connect button
	g.conn = newFlatButton(body, "Connect", cPrim, cPrimDk, font(12, walk.FontBold), g.toggle)
	g.conn.SetMinMaxSize(walk.Size{Height: 50}, walk.Size{Height: 50})

	// profile row
	row, _ := walk.NewComposite(body)
	row.SetBackground(brush(cBG))
	rl := walk.NewHBoxLayout()
	rl.SetMargins(walk.Margins{})
	rl.SetSpacing(8)
	row.SetLayout(rl)
	g.cmb, _ = walk.NewComboBox(row)
	g.cmb.SetFont(font(10, 0))
	darkControl(g.cmb, "DarkMode_CFD")
	small := font(9, walk.FontBold)
	for _, b := range []struct {
		t  string
		bg walk.Color
		fg walk.Color
		fn func()
	}{
		{"New", cCard, cText, func() { g.edit(nil) }},
		{"Import", cCard, cPrim, g.importClipboard},
		{"Edit", cCard, cText, func() { g.edit(g.selected()) }},
		{"Delete", cCard, cErr, g.deleteSelected},
	} {
		fb := newFlatButton(row, b.t, b.bg, b.fg, small, b.fn)
		w := 58
		if b.t == "Import" {
			w = 68
		}
		fb.SetMinMaxSize(walk.Size{Width: w, Height: 30}, walk.Size{Width: w, Height: 30})
	}
	g.reloadProfiles("")

	// log
	hdr, _ := walk.NewLabel(body)
	hdr.SetText("Log")
	hdr.SetTextColor(cMuted)
	hdr.SetFont(font(9, walk.FontBold))
	g.logs, _ = walk.NewTextEdit(body)
	g.logs.SetReadOnly(true)
	g.logs.SetBackground(brush(cInput))
	g.logs.SetTextColor(cMuted)
	g.logs.SetFont(font(8, 0))
	g.logs.SetMinMaxSize(walk.Size{Height: 120}, walk.Size{})
	darkControl(g.logs, "DarkMode_Explorer")

	mw.SetMinMaxSize(walk.Size{Width: 456, Height: 640}, walk.Size{Width: 456, Height: 640})
	mw.SetSize(walk.Size{Width: 456, Height: 640})
	hw := mw.Handle()
	st := win.GetWindowLong(hw, win.GWL_STYLE)
	win.SetWindowLong(hw, win.GWL_STYLE, st&^win.WS_MAXIMIZEBOX&^win.WS_THICKFRAME)
	darkTitleBar(mw)

	// close = hide to tray while connected, otherwise quit
	mw.Closing().Attach(func(cancel *bool, _ walk.CloseReason) {
		if g.quitting || g.snap.State == "idle" || g.snap.State == "error" || g.ni == nil {
			return
		}
		*cancel = true
		mw.Hide()
		g.ni.ShowInfo(appName, "Still running in the tray. Right-click the icon to exit.")
	})

	if g.ni != nil {
		g.ni.MouseDown().Attach(func(x, y int, b walk.MouseButton) {
			if b == walk.LeftButton {
				mw.Show()
				win.SetForegroundWindow(mw.Handle())
			}
		})
		add := func(text string, fn func()) {
			a := walk.NewAction()
			a.SetText(text)
			a.Triggered().Attach(fn)
			g.ni.ContextMenu().Actions().Add(a)
		}
		add("Show", func() { mw.Show(); win.SetForegroundWindow(mw.Handle()) })
		add("Connect / Disconnect", g.toggle)
		add("Exit", func() { g.quitting = true; mw.Close() })
	}

	mw.Show()
	g.refresh()
	return nil
}

func (g *gui) selected() *Profile {
	i := g.cmb.CurrentIndex()
	if i < 0 || i >= len(g.profiles) {
		return nil
	}
	return g.profiles[i]
}

func (g *gui) reloadProfiles(sel string) {
	g.profiles = g.app.store.List()
	names := make([]string, len(g.profiles))
	idx := 0
	for i, p := range g.profiles {
		names[i] = p.Name
		if p.Name == sel {
			idx = i
		}
	}
	g.cmb.SetModel(names)
	if len(names) > 0 {
		g.cmb.SetCurrentIndex(idx)
	}
}

// importClipboard creates profiles from a link copied in the CK.VPN panel
// (ssh:// link, list of links, or the subscription URL).
func (g *gui) importClipboard() {
	text, err := walk.Clipboard().Text()
	if err != nil || strings.TrimSpace(text) == "" {
		walk.MsgBox(g.mw, appName, "The clipboard is empty.\r\nIn the panel copy an account link (SSH link / subscription link), then press Import.", walk.MsgBoxIconInformation)
		return
	}
	go func() {
		profs, err := ImportFromText(text)
		g.mw.Synchronize(func() {
			if err != nil {
				walk.MsgBox(g.mw, appName, err.Error(), walk.MsgBoxIconWarning)
				return
			}
			names, err := storeImported(g.app.store, profs)
			if len(names) > 0 {
				g.reloadProfiles(names[0])
				g.app.logf("imported %d profile(s) from the clipboard: %s", len(names), strings.Join(names, ", "))
			}
			if err != nil {
				walk.MsgBox(g.mw, appName, "Import stopped: "+err.Error(), walk.MsgBoxIconError)
				return
			}
			walk.MsgBox(g.mw, appName, fmt.Sprintf("Imported %d profile(s):\r\n%s", len(names), strings.Join(names, "\r\n")), walk.MsgBoxIconInformation)
		})
	}()
}

func (g *gui) deleteSelected() {
	p := g.selected()
	if p == nil {
		return
	}
	if walk.MsgBox(g.mw, appName, "Delete profile \""+p.Name+"\"?", walk.MsgBoxYesNo|walk.MsgBoxIconQuestion) == win.IDYES {
		g.app.store.Delete(p.Name)
		g.reloadProfiles("")
	}
}

func (g *gui) toggle() {
	s := g.app.Snapshot().State
	if s == "connected" || s == "connecting" {
		go g.app.Disconnect()
		return
	}
	p := g.selected()
	if p == nil {
		walk.MsgBox(g.mw, appName, "Create a profile first (New).", walk.MsgBoxIconInformation)
		return
	}
	go func() {
		if err := g.app.Connect(p.Name); err != nil {
			g.mw.Synchronize(func() { g.refresh() })
		}
	}()
}

func (g *gui) refresh() {
	g.snap = g.app.Snapshot()
	s := g.snap
	switch s.State {
	case "connected", "connecting":
		g.conn.set("Disconnect", cErr, walk.RGB(255, 255, 255))
	default:
		g.conn.set("Connect", cPrim, cPrimDk)
	}
	g.conn.enabled = s.State != "connecting"
	g.hero.Invalidate()
	if len(s.Logs) != g.logCount {
		g.logCount = len(s.Logs)
		g.logs.SetText(strings.Join(s.Logs, "\r\n"))
		g.logs.SendMessage(win.EM_SCROLLCARET, 0, 0)
		n := g.logs.TextLength()
		g.logs.SetTextSelection(n, n)
		g.logs.SendMessage(win.EM_SCROLLCARET, 0, 0)
	}
	if g.ni != nil {
		tip := appName + " - " + stateText(s.State)
		if s.State == "connected" && s.PingMs >= 0 {
			tip += fmt.Sprintf(" - %d ms", s.PingMs)
		}
		g.ni.SetToolTip(tip)
	}
}

func stateText(s string) string {
	switch s {
	case "connected":
		return "Connected"
	case "connecting":
		return "Connecting..."
	case "error":
		return "Error"
	}
	return "Disconnected"
}

func (g *gui) paintHero(c *walk.Canvas, _ walk.Rectangle) error {
	r := g.hero.ClientBoundsPixels()
	dpi := c.DPI()
	px := func(v int) int { return v * dpi / 96 }
	c.FillRectanglePixels(brush(cBG), r)

	// logo + title
	lg := walk.Rectangle{X: px(16), Y: px(16), Width: px(52), Height: px(52)}
	if g.logo != nil {
		c.DrawBitmapWithOpacityPixels(g.logo, lg, 255)
	}
	c.DrawTextPixels("CK Client", font(17, walk.FontBold), cText,
		walk.Rectangle{X: px(80), Y: px(16), Width: r.Width - px(96), Height: px(30)}, walk.TextLeft|walk.TextSingleLine)
	c.DrawTextPixels("SSH  ·  UDPGW  ·  VPN", font(9, 0), cMuted,
		walk.Rectangle{X: px(80), Y: px(46), Width: r.Width - px(96), Height: px(22)}, walk.TextLeft|walk.TextSingleLine)

	// status card
	card := walk.Rectangle{X: px(16), Y: px(84), Width: r.Width - px(32), Height: px(152)}
	c.FillRoundedRectanglePixels(brush(cBorder), card, walk.Size{Width: px(16), Height: px(16)})
	inner := walk.Rectangle{X: card.X + 1, Y: card.Y + 1, Width: card.Width - 2, Height: card.Height - 2}
	c.FillRoundedRectanglePixels(brush(cCard), inner, walk.Size{Width: px(15), Height: px(15)})

	col := cMuted
	switch g.snap.State {
	case "connected":
		col = cOK
	case "connecting":
		col = cWarn
	case "error":
		col = cErr
	}
	d := px(14)
	c.FillEllipsePixels(brush(col), walk.Rectangle{X: card.X + px(18), Y: card.Y + px(20), Width: d, Height: d})
	title := stateText(g.snap.State)
	if g.snap.Active != "" && g.snap.State != "idle" {
		title += "  -  " + g.snap.Active
	}
	c.DrawTextPixels(title, font(12, walk.FontBold), cText,
		walk.Rectangle{X: card.X + px(42), Y: card.Y + px(13), Width: card.Width - px(60), Height: px(28)}, walk.TextLeft|walk.TextSingleLine|walk.TextEndEllipsis)

	sub := ""
	switch {
	case g.snap.State == "error":
		sub = g.snap.Err
	case g.snap.State == "connected" && !g.snap.Since.IsZero():
		sub = "Connected for " + time.Since(g.snap.Since).Round(time.Second).String()
	}
	if sub != "" {
		sc := cMuted
		if g.snap.State == "error" {
			sc = cErr
		}
		c.DrawTextPixels(sub, font(9, 0), sc,
			walk.Rectangle{X: card.X + px(18), Y: card.Y + px(46), Width: card.Width - px(36), Height: px(40)},
			walk.TextLeft|walk.TextWordbreak|walk.TextEndEllipsis)
	}

	// stats
	ping, pingCol := "-", cText
	if g.snap.State == "connected" {
		switch ms := g.snap.PingMs; {
		case !g.snap.Link:
			ping, pingCol = "reconnecting", cWarn
		case ms < 0:
			ping, pingCol = "...", cMuted
		default:
			ping = fmt.Sprintf("%d ms", ms)
			switch {
			case ms < 120:
				pingCol = cOK
			case ms < 300:
				pingCol = cWarn
			default:
				pingCol = cErr
			}
		}
	}
	stats := [][2]string{{"UPLOAD", fmtBytes(g.snap.Up)}, {"DOWNLOAD", fmtBytes(g.snap.Down)}, {"PING", ping}}
	cw := (card.Width - px(36)) / 3
	for i, s := range stats {
		x := card.X + px(18) + i*cw
		c.DrawTextPixels(s[0], font(8, 0), cMuted, walk.Rectangle{X: x, Y: card.Y + px(92), Width: cw, Height: px(18)}, walk.TextLeft|walk.TextSingleLine)
		vc := cText
		if i == 2 {
			vc = pingCol
		}
		c.DrawTextPixels(s[1], font(11, walk.FontBold), vc, walk.Rectangle{X: x, Y: card.Y + px(110), Width: cw, Height: px(26)}, walk.TextLeft|walk.TextSingleLine)
	}
	return nil
}

// ---------------------------------------------------------------- profile editor

func (g *gui) edit(p *Profile) {
	isNew := p == nil
	if isNew {
		p = &Profile{UdpgwEnabled: true}
		p.applyDefaults()
	}
	dlg, err := walk.NewDialog(g.mw)
	if err != nil {
		return
	}
	title := "Edit profile"
	if isNew {
		title = "New profile"
	}
	dlg.SetTitle(title)
	dlg.SetBackground(brush(cBG))
	dlg.SetIcon(g.mw.Icon())
	vl := walk.NewVBoxLayout()
	vl.SetMargins(walk.Margins{HNear: 18, VNear: 16, HFar: 18, VFar: 16})
	vl.SetSpacing(6)
	dlg.SetLayout(vl)

	label := func(t string) {
		l, _ := walk.NewLabel(dlg)
		l.SetText(t)
		l.SetTextColor(cMuted)
		l.SetFont(font(9, 0))
	}
	input := func(v string) *walk.LineEdit {
		e, _ := walk.NewLineEdit(dlg)
		e.SetText(v)
		e.SetBackground(brush(cInput))
		e.SetTextColor(cText)
		e.SetFont(font(10, 0))
		darkControl(e, "DarkMode_CFD")
		return e
	}
	combo := func(items []string, idx int) *walk.ComboBox {
		c, _ := walk.NewComboBox(dlg)
		c.SetFont(font(10, 0))
		c.SetModel(items)
		c.SetCurrentIndex(idx)
		darkControl(c, "DarkMode_CFD")
		return c
	}

	label("Profile name")
	eName := input(p.Name)
	eName.SetReadOnly(!isNew)
	label("Server (IP or domain)")
	eHost := input(p.Host)
	label("SSH port")
	ePort := input(strconv.Itoa(p.Port))
	label("Username")
	eUser := input(p.User)
	label("Password" + map[bool]string{true: " (leave empty to keep the saved one)", false: ""}[!isNew && p.Password != ""])
	ePass := input("")
	ePass.SetPasswordMode(true)
	label("Private key (optional, PEM text)")
	eKey, _ := walk.NewTextEdit(dlg)
	eKey.SetBackground(brush(cInput))
	eKey.SetTextColor(cText)
	eKey.SetFont(font(8, 0))
	eKey.SetMinMaxSize(walk.Size{Height: 52}, walk.Size{Height: 52})
	darkControl(eKey, "DarkMode_Explorer")

	label("Mode")
	modes := []string{"VPN (all apps)", "SOCKS5 proxy only"}
	cMode := combo(modes, map[bool]int{true: 1, false: 0}[p.Mode == "proxy"])
	label("Transport")
	cTr := combo([]string{"SSH direct", "SSH over TLS (SNI)"}, map[bool]int{true: 1, false: 0}[p.Transport == "tls"])
	label("SNI (TLS only)")
	eSNI := input(p.SNI)
	label("UDPGW")
	cGW := combo([]string{"Enabled", "Disabled"}, map[bool]int{true: 0, false: 1}[p.UdpgwEnabled])
	label("UDPGW address (as seen from the server)")
	eGW := input(p.UdpgwAddr)
	label("DNS servers (comma separated)")
	eDNS := input(strings.Join(p.DNS, ","))
	label("Ping target host:port (measured through the tunnel; \"off\" = SSH server only)")
	ePing := input(p.PingTarget)
	label("Local SOCKS5 port (proxy mode)")
	eSocks := input(strconv.Itoa(p.SocksPort))

	bar, _ := walk.NewComposite(dlg)
	bar.SetBackground(brush(cBG))
	bl := walk.NewHBoxLayout()
	bl.SetMargins(walk.Margins{VNear: 10})
	bl.SetSpacing(10)
	bar.SetLayout(bl)
	f := font(10, walk.FontBold)
	save := newFlatButton(bar, "Save", cPrim, cPrimDk, f, func() {
		port, e1 := strconv.Atoi(strings.TrimSpace(ePort.Text()))
		sp, e2 := strconv.Atoi(strings.TrimSpace(eSocks.Text()))
		if e1 != nil || e2 != nil {
			walk.MsgBox(dlg, appName, "Port must be a number.", walk.MsgBoxIconWarning)
			return
		}
		np := &Profile{
			Name: strings.TrimSpace(eName.Text()), Host: strings.TrimSpace(eHost.Text()), Port: port,
			User: strings.TrimSpace(eUser.Text()), Password: ePass.Text(), PrivateKey: strings.TrimSpace(eKey.Text()),
			Mode: []string{"vpn", "proxy"}[max(cMode.CurrentIndex(), 0)], Transport: []string{"direct", "tls"}[max(cTr.CurrentIndex(), 0)],
			SNI: strings.TrimSpace(eSNI.Text()), UdpgwEnabled: cGW.CurrentIndex() == 0, UdpgwAddr: strings.TrimSpace(eGW.Text()),
			SocksPort: sp, PingTarget: strings.TrimSpace(ePing.Text()),
		}
		for _, d := range strings.Split(eDNS.Text(), ",") {
			if d = strings.TrimSpace(d); d != "" {
				np.DNS = append(np.DNS, d)
			}
		}
		if pt := strings.ToLower(np.PingTarget); pt != "" && pt != "off" {
			if _, _, err := net.SplitHostPort(np.PingTarget); err != nil {
				walk.MsgBox(dlg, appName, "Ping target must look like host:port (for example 1.1.1.1:443) or \"off\".", walk.MsgBoxIconWarning)
				return
			}
		}
		if np.Name == "" || np.Host == "" || np.User == "" {
			walk.MsgBox(dlg, appName, "Name, server and username are required.", walk.MsgBoxIconWarning)
			return
		}
		if old := g.app.store.Get(np.Name); old != nil {
			if np.Password == "" {
				np.Password = old.Password
			}
			if np.PrivateKey == "" {
				np.PrivateKey = old.PrivateKey
			}
		}
		if np.Password == "" && np.PrivateKey == "" {
			walk.MsgBox(dlg, appName, "Enter a password or a private key.", walk.MsgBoxIconWarning)
			return
		}
		if err := g.app.store.Put(np); err != nil {
			walk.MsgBox(dlg, appName, err.Error(), walk.MsgBoxIconError)
			return
		}
		g.reloadProfiles(np.Name)
		dlg.Accept()
	})
	save.SetMinMaxSize(walk.Size{Height: 40}, walk.Size{Height: 40})
	cancel := newFlatButton(bar, "Cancel", cCard, cText, f, func() { dlg.Cancel() })
	cancel.SetMinMaxSize(walk.Size{Height: 40}, walk.Size{Height: 40})
	if !isNew {
		fg := newFlatButton(bar, "Forget host key", cCard, cMuted, font(8, 0), func() {
			g.app.store.PinHostKey(p.Name, "")
			walk.MsgBox(dlg, appName, "Saved server key removed. It will be trusted again on the next connect.", walk.MsgBoxIconInformation)
		})
		fg.SetMinMaxSize(walk.Size{Height: 40}, walk.Size{Height: 40})
	}

	dlg.SetMinMaxSize(walk.Size{Width: 400}, walk.Size{Width: 400})
	darkTitleBar(dlg)
	dlg.Run()
}
