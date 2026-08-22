// Package assets manages typed, reloadable runtime assets.
package assets

import (
	"fmt"
	"io"
	"io/fs"
	"reflect"
	"sort"
	"sync"

	"github.com/gongahkia/72/engine/diagnostics"
)

// Handle identifies an asset of type T. Handles remain valid after Reload;
// callers retrieve the current value through Get.
type Handle[T any] struct{ id uint64 }

// ID is an untyped asset identity for dependency metadata and diagnostics.
type ID uint64

// AssetID returns handle's untyped identity.
func (h Handle[T]) AssetID() ID { return ID(h.id) }

// Loader decodes an asset from its project-relative source path.
type Loader[T any] func(path string, source io.Reader) (T, error)

// Entry is one asset's build/package manifest metadata.
type Entry struct {
	ID           ID
	Path         string
	Type         string
	Dependencies []ID
}

type record struct {
	path         string
	typeID       reflect.Type
	value        any
	dependencies []ID
	callbacks    []func()
}

// Manager owns assets loaded from a project filesystem. A Manager is safe for
// concurrent use when its fs.FS implementation is safe for concurrent reads.
type Manager struct {
	fs fs.FS

	mu     sync.RWMutex
	nextID uint64
	byID   map[ID]*record
	byKey  map[assetKey]ID
}

type assetKey struct {
	path   string
	typeID reflect.Type
}

// NewManager creates a manager over source. Paths passed to Load are required
// to be valid project-relative fs paths.
func NewManager(source fs.FS) *Manager {
	return &Manager{
		fs:    source,
		byID:  make(map[ID]*record),
		byKey: make(map[assetKey]ID),
	}
}

// Load decodes a typed asset. Repeated calls for the same path and type return
// its stable handle and current value without decoding it again.
func Load[T any](manager *Manager, path string, loader Loader[T]) (Handle[T], error) {
	var zero Handle[T]
	if err := validLoad(path, loader); err != nil {
		return zero, assetFailure("validate asset request", err, diagnostics.CorrectInput)
	}
	typeID := typeOf[T]()
	key := assetKey{path: path, typeID: typeID}
	manager.mu.RLock()
	if id, ok := manager.byKey[key]; ok {
		manager.mu.RUnlock()
		return Handle[T]{id: uint64(id)}, nil
	}
	manager.mu.RUnlock()

	value, err := decode(manager.fs, path, loader)
	if err != nil {
		return zero, assetFailure("load asset", err, diagnostics.CorrectInput)
	}
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if id, ok := manager.byKey[key]; ok {
		return Handle[T]{id: uint64(id)}, nil
	}
	manager.nextID++
	id := ID(manager.nextID)
	manager.byID[id] = &record{path: path, typeID: typeID, value: value}
	manager.byKey[key] = id
	return Handle[T]{id: uint64(id)}, nil
}

// LoadAsync begins Load in a goroutine and delivers exactly one result.
func LoadAsync[T any](manager *Manager, path string, loader Loader[T]) <-chan Result[T] {
	result := make(chan Result[T], 1)
	go func() {
		handle, err := Load(manager, path, loader)
		result <- Result[T]{Handle: handle, Err: err}
		close(result)
	}()
	return result
}

// Result is an asynchronous load result.
type Result[T any] struct {
	Handle Handle[T]
	Err    error
}

// Get retrieves a typed loaded asset.
func Get[T any](manager *Manager, handle Handle[T]) (T, bool) {
	var zero T
	manager.mu.RLock()
	record := manager.byID[ID(handle.id)]
	manager.mu.RUnlock()
	if record == nil || record.typeID != typeOf[T]() {
		return zero, false
	}
	value, ok := record.value.(T)
	return value, ok
}

// Reload replaces an already-loaded asset's value while preserving its handle.
// Subscribers run after the new value becomes observable.
func Reload[T any](manager *Manager, handle Handle[T], loader Loader[T]) error {
	if loader == nil {
		return assetFailure("reload asset", fmt.Errorf("asset loader must not be nil"), diagnostics.CorrectInput)
	}
	manager.mu.RLock()
	record := manager.byID[ID(handle.id)]
	if record == nil || record.typeID != typeOf[T]() {
		manager.mu.RUnlock()
		return assetFailure("reload asset", fmt.Errorf("asset handle %d is not a loaded %s", handle.id, typeOf[T]()), diagnostics.CorrectInput)
	}
	path := record.path
	manager.mu.RUnlock()
	value, err := decode(manager.fs, path, loader)
	if err != nil {
		return assetFailure("reload asset", err, diagnostics.Retry)
	}
	manager.mu.Lock()
	record = manager.byID[ID(handle.id)]
	record.value = value
	callbacks := append([]func(){}, record.callbacks...)
	manager.mu.Unlock()
	for _, callback := range callbacks {
		callback()
	}
	return nil
}

// OnReload adds a callback invoked after a matching asset is reloaded.
func OnReload[T any](manager *Manager, handle Handle[T], callback func()) error {
	if callback == nil {
		return fmt.Errorf("reload callback must not be nil")
	}
	manager.mu.Lock()
	defer manager.mu.Unlock()
	record := manager.byID[ID(handle.id)]
	if record == nil || record.typeID != typeOf[T]() {
		return fmt.Errorf("asset handle %d is not a loaded %s", handle.id, typeOf[T]())
	}
	record.callbacks = append(record.callbacks, callback)
	return nil
}

// SetDependencies sets package-manifest dependencies for a loaded asset.
func SetDependencies[T any](manager *Manager, handle Handle[T], dependencies ...ID) error {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	record := manager.byID[ID(handle.id)]
	if record == nil || record.typeID != typeOf[T]() {
		return fmt.Errorf("asset handle %d is not a loaded %s", handle.id, typeOf[T]())
	}
	for _, dependency := range dependencies {
		if manager.byID[dependency] == nil {
			return fmt.Errorf("asset dependency %d is not loaded", dependency)
		}
	}
	record.dependencies = append(record.dependencies[:0], dependencies...)
	return nil
}

// Manifest returns a stable, package-ready view of loaded assets.
func (manager *Manager) Manifest() []Entry {
	manager.mu.RLock()
	entries := make([]Entry, 0, len(manager.byID))
	for id, record := range manager.byID {
		entries = append(entries, Entry{
			ID:           id,
			Path:         record.path,
			Type:         record.typeID.String(),
			Dependencies: append([]ID(nil), record.dependencies...),
		})
	}
	manager.mu.RUnlock()
	sort.Slice(entries, func(left, right int) bool { return entries[left].ID < entries[right].ID })
	return entries
}

func validLoad[T any](path string, loader Loader[T]) error {
	if !fs.ValidPath(path) {
		return fmt.Errorf("asset path %q must be project-relative", path)
	}
	if loader == nil {
		return fmt.Errorf("asset loader must not be nil")
	}
	return nil
}

func decode[T any](source fs.FS, path string, loader Loader[T]) (T, error) {
	var zero T
	if source == nil {
		return zero, fmt.Errorf("asset filesystem must not be nil")
	}
	file, err := source.Open(path)
	if err != nil {
		return zero, fmt.Errorf("open asset %q: %w", path, err)
	}
	defer file.Close()
	value, err := loader(path, file)
	if err != nil {
		return zero, fmt.Errorf("decode asset %q: %w", path, err)
	}
	return value, nil
}

func typeOf[T any]() reflect.Type { return reflect.TypeOf((*T)(nil)).Elem() }

func assetFailure(operation string, cause error, recovery diagnostics.Recovery) error {
	return diagnostics.NewFailure(diagnostics.AssetsSubsystem, operation, cause, recovery, false)
}
