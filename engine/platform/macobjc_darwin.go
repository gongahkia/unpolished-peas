//go:build darwin

package platform

import (
	"fmt"
	"runtime"
	"strings"
	"unicode/utf8"
	"unsafe"

	"github.com/go-webgpu/goffi/ffi"
	"github.com/go-webgpu/goffi/types"
)

type macRuntime struct {
	libraries []unsafe.Pointer
	getClass  unsafe.Pointer
	selector  unsafe.Pointer
	msgSend   unsafe.Pointer
	msgStret  unsafe.Pointer

	classes   map[string]uintptr
	selectors map[string]uintptr
	cString   types.CallInterface
}

type macArgument struct {
	typ       *types.TypeDescriptor
	pointer   unsafe.Pointer
	keepAlive any
}

type macPoint struct{ X, Y float64 }
type macSize struct{ Width, Height float64 }
type macRect struct {
	Origin macPoint
	Size   macSize
}

var (
	macPointType = &types.TypeDescriptor{Kind: types.StructType, Members: []*types.TypeDescriptor{types.DoubleTypeDescriptor, types.DoubleTypeDescriptor}}
	macSizeType  = &types.TypeDescriptor{Kind: types.StructType, Members: []*types.TypeDescriptor{types.DoubleTypeDescriptor, types.DoubleTypeDescriptor}}
	macRectType  = &types.TypeDescriptor{Kind: types.StructType, Members: []*types.TypeDescriptor{macPointType, macSizeType}}
)

func newMacRuntime() (*macRuntime, error) {
	rt := &macRuntime{classes: make(map[string]uintptr), selectors: make(map[string]uintptr)}
	for _, path := range []string{
		"/usr/lib/libobjc.A.dylib",
		"/System/Library/Frameworks/Foundation.framework/Foundation",
		"/System/Library/Frameworks/AppKit.framework/AppKit",
		"/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
	} {
		library, err := ffi.LoadLibrary(path)
		if err != nil {
			return nil, fmt.Errorf("load macOS framework %q: %w", path, err)
		}
		rt.libraries = append(rt.libraries, library)
	}
	var err error
	if rt.getClass, err = ffi.GetSymbol(rt.libraries[0], "objc_getClass"); err != nil {
		return nil, fmt.Errorf("resolve objc_getClass: %w", err)
	}
	if rt.selector, err = ffi.GetSymbol(rt.libraries[0], "sel_registerName"); err != nil {
		return nil, fmt.Errorf("resolve sel_registerName: %w", err)
	}
	if rt.msgSend, err = ffi.GetSymbol(rt.libraries[0], "objc_msgSend"); err != nil {
		return nil, fmt.Errorf("resolve objc_msgSend: %w", err)
	}
	if runtime.GOARCH == "amd64" {
		if rt.msgStret, err = ffi.GetSymbol(rt.libraries[0], "objc_msgSend_stret"); err != nil {
			return nil, fmt.Errorf("resolve objc_msgSend_stret: %w", err)
		}
	}
	if err := ffi.PrepareCallInterface(&rt.cString, types.DefaultCall, types.PointerTypeDescriptor, []*types.TypeDescriptor{types.PointerTypeDescriptor}); err != nil {
		return nil, fmt.Errorf("prepare Objective-C name call: %w", err)
	}
	for _, name := range []string{"NSApplication", "NSWindow", "NSView", "CAMetalLayer", "NSString", "NSAutoreleasePool", "NSCursor", "NSPasteboard", "NSThread"} {
		if _, err := rt.class(name); err != nil {
			return nil, err
		}
	}
	return rt, nil
}

func (r *macRuntime) close() {
	for index := len(r.libraries) - 1; index >= 0; index-- {
		_ = ffi.FreeLibrary(r.libraries[index])
	}
	r.libraries = nil
}

func (r *macRuntime) class(name string) (uintptr, error) {
	if value := r.classes[name]; value != 0 {
		return value, nil
	}
	value, err := r.callCString(r.getClass, name)
	if err != nil {
		return 0, fmt.Errorf("look up Objective-C class %q: %w", name, err)
	}
	if value == 0 {
		return 0, fmt.Errorf("look up Objective-C class %q: class is unavailable", name)
	}
	r.classes[name] = value
	return value, nil
}

func (r *macRuntime) sel(name string) (uintptr, error) {
	if value := r.selectors[name]; value != 0 {
		return value, nil
	}
	value, err := r.callCString(r.selector, name)
	if err != nil {
		return 0, fmt.Errorf("register Objective-C selector %q: %w", name, err)
	}
	if value == 0 {
		return 0, fmt.Errorf("register Objective-C selector %q: selector is unavailable", name)
	}
	r.selectors[name] = value
	return value, nil
}

func (r *macRuntime) callCString(function unsafe.Pointer, name string) (uintptr, error) {
	encoded := append([]byte(name), 0)
	pointer := unsafe.Pointer(&encoded[0])
	var result uintptr
	if _, err := ffi.CallFunction(&r.cString, function, unsafe.Pointer(&result), []unsafe.Pointer{unsafe.Pointer(&pointer)}); err != nil {
		return 0, err
	}
	runtime.KeepAlive(encoded)
	return result, nil
}

func (r *macRuntime) call(returnType *types.TypeDescriptor, result unsafe.Pointer, receiver, selector uintptr, arguments ...macArgument) error {
	argumentTypes := make([]*types.TypeDescriptor, 0, len(arguments)+2)
	argumentTypes = append(argumentTypes, types.PointerTypeDescriptor, types.PointerTypeDescriptor)
	for _, argument := range arguments {
		argumentTypes = append(argumentTypes, argument.typ)
	}
	cif := &types.CallInterface{}
	if err := ffi.PrepareCallInterface(cif, types.DefaultCall, returnType, argumentTypes); err != nil {
		return err
	}
	receiverValue, selectorValue := receiver, selector
	pointers := make([]unsafe.Pointer, 0, len(arguments)+2)
	pointers = append(pointers, unsafe.Pointer(&receiverValue), unsafe.Pointer(&selectorValue))
	for _, argument := range arguments {
		pointers = append(pointers, argument.pointer)
	}
	function := r.msgSend
	if returnType == macRectType && runtime.GOARCH == "amd64" {
		function = r.msgStret
	}
	if _, err := ffi.CallFunction(cif, function, result, pointers); err != nil {
		return err
	}
	runtime.KeepAlive(arguments)
	return nil
}

func (r *macRuntime) id(receiver uintptr, selector string, arguments ...macArgument) (uintptr, error) {
	sel, err := r.sel(selector)
	if err != nil {
		return 0, err
	}
	var result uintptr
	if err := r.call(types.PointerTypeDescriptor, unsafe.Pointer(&result), receiver, sel, arguments...); err != nil {
		return 0, fmt.Errorf("send %s: %w", selector, err)
	}
	return result, nil
}

func (r *macRuntime) pointer(receiver uintptr, selector string, arguments ...macArgument) (unsafe.Pointer, error) {
	sel, err := r.sel(selector)
	if err != nil {
		return nil, err
	}
	var result unsafe.Pointer
	if err := r.call(types.PointerTypeDescriptor, unsafe.Pointer(&result), receiver, sel, arguments...); err != nil {
		return nil, fmt.Errorf("send %s: %w", selector, err)
	}
	return result, nil
}

func (r *macRuntime) bool(receiver uintptr, selector string, arguments ...macArgument) (bool, error) {
	sel, err := r.sel(selector)
	if err != nil {
		return false, err
	}
	var result uint8
	if err := r.call(types.UInt8TypeDescriptor, unsafe.Pointer(&result), receiver, sel, arguments...); err != nil {
		return false, fmt.Errorf("send %s: %w", selector, err)
	}
	return result != 0, nil
}

func (r *macRuntime) uint64(receiver uintptr, selector string, arguments ...macArgument) (uint64, error) {
	sel, err := r.sel(selector)
	if err != nil {
		return 0, err
	}
	var result uint64
	if err := r.call(types.UInt64TypeDescriptor, unsafe.Pointer(&result), receiver, sel, arguments...); err != nil {
		return 0, fmt.Errorf("send %s: %w", selector, err)
	}
	return result, nil
}

func (r *macRuntime) int64(receiver uintptr, selector string, arguments ...macArgument) (int64, error) {
	sel, err := r.sel(selector)
	if err != nil {
		return 0, err
	}
	var result int64
	if err := r.call(types.SInt64TypeDescriptor, unsafe.Pointer(&result), receiver, sel, arguments...); err != nil {
		return 0, fmt.Errorf("send %s: %w", selector, err)
	}
	return result, nil
}

func (r *macRuntime) uint16(receiver uintptr, selector string, arguments ...macArgument) (uint16, error) {
	sel, err := r.sel(selector)
	if err != nil {
		return 0, err
	}
	var result uint16
	if err := r.call(types.UInt16TypeDescriptor, unsafe.Pointer(&result), receiver, sel, arguments...); err != nil {
		return 0, fmt.Errorf("send %s: %w", selector, err)
	}
	return result, nil
}

func (r *macRuntime) double(receiver uintptr, selector string, arguments ...macArgument) (float64, error) {
	sel, err := r.sel(selector)
	if err != nil {
		return 0, err
	}
	var result float64
	if err := r.call(types.DoubleTypeDescriptor, unsafe.Pointer(&result), receiver, sel, arguments...); err != nil {
		return 0, fmt.Errorf("send %s: %w", selector, err)
	}
	return result, nil
}

func (r *macRuntime) rect(receiver uintptr, selector string, arguments ...macArgument) (macRect, error) {
	sel, err := r.sel(selector)
	if err != nil {
		return macRect{}, err
	}
	var result macRect
	if err := r.call(macRectType, unsafe.Pointer(&result), receiver, sel, arguments...); err != nil {
		return macRect{}, fmt.Errorf("send %s: %w", selector, err)
	}
	return result, nil
}

func (r *macRuntime) callPoint(receiver uintptr, selector string, arguments ...macArgument) (macPoint, error) {
	sel, err := r.sel(selector)
	if err != nil {
		return macPoint{}, err
	}
	var result macPoint
	if err := r.call(macPointType, unsafe.Pointer(&result), receiver, sel, arguments...); err != nil {
		return macPoint{}, fmt.Errorf("send %s: %w", selector, err)
	}
	return result, nil
}

func (r *macRuntime) void(receiver uintptr, selector string, arguments ...macArgument) error {
	sel, err := r.sel(selector)
	if err != nil {
		return err
	}
	if err := r.call(types.VoidTypeDescriptor, nil, receiver, sel, arguments...); err != nil {
		return fmt.Errorf("send %s: %w", selector, err)
	}
	return nil
}

func macPointer(value uintptr) macArgument {
	copy := value
	return macArgument{typ: types.PointerTypeDescriptor, pointer: unsafe.Pointer(&copy), keepAlive: &copy}
}

func macUint64(value uint64) macArgument {
	copy := value
	return macArgument{typ: types.UInt64TypeDescriptor, pointer: unsafe.Pointer(&copy), keepAlive: &copy}
}

func macInt64(value int64) macArgument {
	copy := value
	return macArgument{typ: types.SInt64TypeDescriptor, pointer: unsafe.Pointer(&copy), keepAlive: &copy}
}

func macBool(value bool) macArgument {
	var copy uint8
	if value {
		copy = 1
	}
	return macArgument{typ: types.UInt8TypeDescriptor, pointer: unsafe.Pointer(&copy), keepAlive: &copy}
}

func macDouble(value float64) macArgument {
	copy := value
	return macArgument{typ: types.DoubleTypeDescriptor, pointer: unsafe.Pointer(&copy), keepAlive: &copy}
}

func macRectArgument(value macRect) macArgument {
	copy := value
	return macArgument{typ: macRectType, pointer: unsafe.Pointer(&copy), keepAlive: &copy}
}

func macSizeArgument(value macSize) macArgument {
	copy := value
	return macArgument{typ: macSizeType, pointer: unsafe.Pointer(&copy), keepAlive: &copy}
}

func macUTF8(value string) (macArgument, error) {
	if !utf8.ValidString(value) || strings.IndexByte(value, 0) >= 0 {
		return macArgument{}, fmt.Errorf("value must be valid UTF-8 without NUL")
	}
	encoded := append([]byte(value), 0)
	pointer := unsafe.Pointer(&encoded[0])
	return macArgument{typ: types.PointerTypeDescriptor, pointer: unsafe.Pointer(&pointer), keepAlive: encoded}, nil
}
