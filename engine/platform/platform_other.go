//go:build !linux && !(js && wasm)

package platform

import (
	"fmt"

	"github.com/gongahkia/72/engine"
)

// Run is deliberately explicit on desktop targets whose native host has not
// yet received a runtime validation implementation. The package still builds
// there so target builds distinguish compilation from platform support.
func Run(engine.Config, engine.Application) error {
	return fmt.Errorf("72 native host is not implemented for %s", runtimeTarget())
}
