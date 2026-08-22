//go:build linux

package platform

import (
	"errors"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"github.com/gongahkia/72/engine"
	"golang.org/x/sys/unix"
)

const (
	evdevEventKey = 0x01
	evdevEventAbs = 0x03

	evdevAbsX     = 0x00
	evdevAbsY     = 0x01
	evdevAbsZ     = 0x02
	evdevAbsRX    = 0x03
	evdevAbsRY    = 0x04
	evdevAbsRZ    = 0x05
	evdevAbsHat0X = 0x10
	evdevAbsHat0Y = 0x11

	evdevButtonSouth        = 0x130
	evdevButtonEast         = 0x131
	evdevButtonNorth        = 0x133
	evdevButtonWest         = 0x134
	evdevButtonLeftBumper   = 0x136
	evdevButtonRightBumper  = 0x137
	evdevButtonLeftTrigger  = 0x138
	evdevButtonRightTrigger = 0x139
	evdevButtonSelect       = 0x13a
	evdevButtonStart        = 0x13b
	evdevButtonHome         = 0x13c
	evdevButtonLeftStick    = 0x13d
	evdevButtonRightStick   = 0x13e
	evdevButtonDPadUp       = 0x220
	evdevButtonDPadDown     = 0x221
	evdevButtonDPadLeft     = 0x222
	evdevButtonDPadRight    = 0x223
)

type evdevGamepads struct {
	devices  map[string]*evdevGamepad
	nextScan time.Time
}

type evdevGamepad struct {
	path    string
	fd      int
	id      uint32
	buttons [17]float64
	axes    [4]float64
}

type evdevEvent struct {
	Time  unix.Timeval
	Type  uint16
	Code  uint16
	Value int32
}

type evdevAbsInfo struct {
	Value      int32
	Minimum    int32
	Maximum    int32
	Fuzz       int32
	Flat       int32
	Resolution int32
}

// newEvdevGamepads treats an unreadable input directory as a capability result,
// never as an X11-host startup failure. evdev is Linux's native device API;
// individual unavailable devices are ignored until the next scan.
func newEvdevGamepads() (*evdevGamepads, engine.InputCapability) {
	entries, err := os.ReadDir("/dev/input")
	if err != nil {
		if errors.Is(err, os.ErrPermission) {
			return nil, engine.InputRestricted
		}
		return nil, engine.InputUnavailable
	}
	opened, restricted := false, false
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasPrefix(entry.Name(), "event") {
			continue
		}
		fd, openErr := unix.Open(filepath.Join("/dev/input", entry.Name()), unix.O_RDONLY|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
		if openErr == nil {
			opened = true
			_ = unix.Close(fd)
			continue
		}
		if errors.Is(openErr, unix.EACCES) || errors.Is(openErr, unix.EPERM) {
			restricted = true
		}
	}
	if restricted && !opened {
		return nil, engine.InputRestricted
	}
	manager := &evdevGamepads{devices: make(map[string]*evdevGamepad)}
	return manager, engine.InputAvailable
}

func (m *evdevGamepads) poll(events *[]engine.Event) {
	if m == nil {
		return
	}
	now := time.Now()
	if !now.Before(m.nextScan) {
		entries, err := os.ReadDir("/dev/input")
		if err == nil {
			m.scan(entries, events)
		}
		m.nextScan = now.Add(time.Second)
	}
	for path, gamepad := range m.devices {
		if m.read(gamepad, events) {
			continue
		}
		m.disconnect(path, events)
	}
}

func (m *evdevGamepads) scan(entries []os.DirEntry, events *[]engine.Event) {
	paths := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasPrefix(entry.Name(), "event") {
			continue
		}
		paths = append(paths, filepath.Join("/dev/input", entry.Name()))
	}
	sort.Strings(paths)
	seen := make(map[string]struct{}, len(paths))
	for _, path := range paths {
		seen[path] = struct{}{}
		if _, exists := m.devices[path]; exists {
			continue
		}
		gamepad, ok := openEvdevGamepad(path)
		if !ok {
			continue
		}
		m.devices[path] = gamepad
		if events != nil {
			*events = append(*events, engine.Event{Kind: engine.EventGamepadConnection, DeviceID: gamepad.id, Connected: true, GamepadMapping: engine.GamepadMappingStandard})
			gamepad.appendSnapshot(events)
		}
	}
	for path := range m.devices {
		if _, exists := seen[path]; !exists {
			m.disconnect(path, events)
		}
	}
}

func openEvdevGamepad(path string) (*evdevGamepad, bool) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, false
	}
	if !evdevIsGamepad(fd) {
		_ = unix.Close(fd)
		return nil, false
	}
	name := filepath.Base(path)
	index, err := strconv.ParseUint(strings.TrimPrefix(name, "event"), 10, 32)
	if err != nil {
		_ = unix.Close(fd)
		return nil, false
	}
	gamepad := &evdevGamepad{path: path, fd: fd, id: uint32(index)}
	gamepad.readInitialState()
	return gamepad, true
}

func evdevIsGamepad(fd int) bool {
	types := make([]byte, 8)
	if !evdevIoctlBytes(fd, evdevIOCGetBits(0, len(types)), types) || !evdevBit(types, evdevEventKey) || !evdevBit(types, evdevEventAbs) {
		return false
	}
	keys := make([]byte, 96)
	if !evdevIoctlBytes(fd, evdevIOCGetBits(evdevEventKey, len(keys)), keys) {
		return false
	}
	for code := evdevButtonSouth; code <= evdevButtonRightStick; code++ {
		if evdevBit(keys, code) {
			return true
		}
	}
	return false
}

func (m *evdevGamepads) read(gamepad *evdevGamepad, events *[]engine.Event) bool {
	buffer := make([]byte, unsafe.Sizeof(evdevEvent{})*16)
	for {
		count, err := unix.Read(gamepad.fd, buffer)
		if err != nil {
			if errors.Is(err, unix.EAGAIN) || errors.Is(err, unix.EWOULDBLOCK) {
				return true
			}
			return false
		}
		if count == 0 {
			return false
		}
		eventsRead := unsafe.Slice((*evdevEvent)(unsafe.Pointer(&buffer[0])), count/int(unsafe.Sizeof(evdevEvent{})))
		for _, event := range eventsRead {
			gamepad.apply(event, events)
		}
		if count < len(buffer) {
			return true
		}
	}
}

func (m *evdevGamepads) disconnect(path string, events *[]engine.Event) {
	gamepad := m.devices[path]
	if gamepad == nil {
		return
	}
	_ = unix.Close(gamepad.fd)
	delete(m.devices, path)
	if events != nil {
		*events = append(*events, engine.Event{Kind: engine.EventGamepadConnection, DeviceID: gamepad.id, Connected: false, GamepadMapping: engine.GamepadMappingStandard})
	}
}

func (m *evdevGamepads) close() {
	if m == nil {
		return
	}
	for path := range m.devices {
		m.disconnect(path, nil)
	}
}

func (g *evdevGamepad) readInitialState() {
	keys := make([]byte, 96)
	if evdevIoctlBytes(g.fd, evdevIOCGetKey(len(keys)), keys) {
		for code, button := range evdevButtons {
			if evdevBit(keys, code) {
				g.buttons[button] = 1
			}
		}
	}
	for code, axis := range evdevAxes {
		if info, ok := evdevReadAbsInfo(g.fd, code); ok {
			g.axes[axis] = evdevNormalizeAxis(info)
		}
	}
	for _, code := range []int{evdevAbsZ, evdevAbsRZ, evdevAbsHat0X, evdevAbsHat0Y} {
		if info, ok := evdevReadAbsInfo(g.fd, code); ok {
			g.applyAbs(uint16(code), info.Value, nil)
		}
	}
}

func (g *evdevGamepad) appendSnapshot(events *[]engine.Event) {
	for button, value := range g.buttons {
		*events = append(*events, engine.Event{Kind: engine.EventGamepadButton, DeviceID: g.id, Button: engine.GamepadButton(button), Value: value, Pressed: value >= .5})
	}
	for axis, value := range g.axes {
		*events = append(*events, engine.Event{Kind: engine.EventGamepadAxis, DeviceID: g.id, Axis: engine.GamepadAxis(axis), Value: value})
	}
}

func (g *evdevGamepad) apply(event evdevEvent, events *[]engine.Event) {
	switch event.Type {
	case evdevEventKey:
		button, ok := evdevButtons[int(event.Code)]
		if !ok {
			return
		}
		value := 0.0
		if event.Value != 0 {
			value = 1
		}
		if g.buttons[button] == value {
			return
		}
		g.buttons[button] = value
		*events = append(*events, engine.Event{Kind: engine.EventGamepadButton, DeviceID: g.id, Button: engine.GamepadButton(button), Value: value, Pressed: value >= .5})
	case evdevEventAbs:
		g.applyAbs(event.Code, event.Value, events)
	}
}

func (g *evdevGamepad) applyAbs(code uint16, raw int32, events *[]engine.Event) {
	if axis, ok := evdevAxes[int(code)]; ok {
		info, known := evdevReadAbsInfo(g.fd, int(code))
		if !known {
			return
		}
		value := evdevNormalizeAxisWithValue(info, raw)
		if g.axes[axis] == value {
			return
		}
		g.axes[axis] = value
		if events != nil {
			*events = append(*events, engine.Event{Kind: engine.EventGamepadAxis, DeviceID: g.id, Axis: engine.GamepadAxis(axis), Value: value})
		}
		return
	}
	if code == evdevAbsZ || code == evdevAbsRZ {
		info, known := evdevReadAbsInfo(g.fd, int(code))
		if !known {
			return
		}
		button := engine.GamepadButtonLeftTrigger
		if code == evdevAbsRZ {
			button = engine.GamepadButtonRightTrigger
		}
		value := evdevNormalizeTrigger(info, raw)
		if g.buttons[button] == value {
			return
		}
		g.buttons[button] = value
		if events != nil {
			*events = append(*events, engine.Event{Kind: engine.EventGamepadButton, DeviceID: g.id, Button: button, Value: value, Pressed: value >= .5})
		}
		return
	}
	if code != evdevAbsHat0X && code != evdevAbsHat0Y {
		return
	}
	buttons := [2]engine.GamepadButton{engine.GamepadButtonDPadLeft, engine.GamepadButtonDPadRight}
	if code == evdevAbsHat0Y {
		buttons = [2]engine.GamepadButton{engine.GamepadButtonDPadUp, engine.GamepadButtonDPadDown}
	}
	values := [2]float64{0, 0}
	if raw < 0 {
		values[0] = 1
	} else if raw > 0 {
		values[1] = 1
	}
	for index, button := range buttons {
		if g.buttons[button] == values[index] {
			continue
		}
		g.buttons[button] = values[index]
		if events != nil {
			*events = append(*events, engine.Event{Kind: engine.EventGamepadButton, DeviceID: g.id, Button: button, Value: values[index], Pressed: values[index] >= .5})
		}
	}
}

var evdevButtons = map[int]engine.GamepadButton{
	evdevButtonSouth: engine.GamepadButtonSouth, evdevButtonEast: engine.GamepadButtonEast, evdevButtonWest: engine.GamepadButtonWest, evdevButtonNorth: engine.GamepadButtonNorth,
	evdevButtonLeftBumper: engine.GamepadButtonLeftBumper, evdevButtonRightBumper: engine.GamepadButtonRightBumper, evdevButtonLeftTrigger: engine.GamepadButtonLeftTrigger, evdevButtonRightTrigger: engine.GamepadButtonRightTrigger,
	evdevButtonSelect: engine.GamepadButtonSelect, evdevButtonStart: engine.GamepadButtonStart, evdevButtonHome: engine.GamepadButtonHome, evdevButtonLeftStick: engine.GamepadButtonLeftStick, evdevButtonRightStick: engine.GamepadButtonRightStick,
	evdevButtonDPadUp: engine.GamepadButtonDPadUp, evdevButtonDPadDown: engine.GamepadButtonDPadDown, evdevButtonDPadLeft: engine.GamepadButtonDPadLeft, evdevButtonDPadRight: engine.GamepadButtonDPadRight,
}

var evdevAxes = map[int]engine.GamepadAxis{
	evdevAbsX: engine.GamepadAxisLeftStickX, evdevAbsY: engine.GamepadAxisLeftStickY, evdevAbsRX: engine.GamepadAxisRightStickX, evdevAbsRY: engine.GamepadAxisRightStickY,
}

func evdevNormalizeAxis(info evdevAbsInfo) float64 {
	return evdevNormalizeAxisWithValue(info, info.Value)
}

func evdevNormalizeAxisWithValue(info evdevAbsInfo, value int32) float64 {
	if info.Minimum >= info.Maximum {
		return 0
	}
	center := float64(info.Minimum+info.Maximum) / 2
	half := float64(info.Maximum-info.Minimum) / 2
	if half == 0 {
		return 0
	}
	return math.Max(-1, math.Min(1, (float64(value)-center)/half))
}

func evdevNormalizeTrigger(info evdevAbsInfo, value int32) float64 {
	if info.Minimum >= info.Maximum {
		return 0
	}
	return math.Max(0, math.Min(1, float64(value-info.Minimum)/float64(info.Maximum-info.Minimum)))
}

func evdevReadAbsInfo(fd, axis int) (evdevAbsInfo, bool) {
	var info evdevAbsInfo
	request := evdevIOCGetAbs(axis)
	_, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), request, uintptr(unsafe.Pointer(&info)))
	return info, errno == 0
}

func evdevIoctlBytes(fd int, request uintptr, value []byte) bool {
	if len(value) == 0 {
		return false
	}
	_, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), request, uintptr(unsafe.Pointer(&value[0])))
	return errno == 0
}

func evdevBit(values []byte, code int) bool {
	index := code / 8
	return index >= 0 && index < len(values) && values[index]&(1<<uint(code%8)) != 0
}

func evdevIOCGetBits(eventType, length int) uintptr { return evdevIOC(2, 'E', 0x20+eventType, length) }
func evdevIOCGetKey(length int) uintptr             { return evdevIOC(2, 'E', 0x18, length) }
func evdevIOCGetAbs(axis int) uintptr {
	return evdevIOC(2, 'E', 0x40+axis, int(unsafe.Sizeof(evdevAbsInfo{})))
}

func evdevIOC(direction, kind, number, size int) uintptr {
	return uintptr(uint32(direction)<<30 | uint32(kind)<<8 | uint32(number) | uint32(size)<<16)
}
