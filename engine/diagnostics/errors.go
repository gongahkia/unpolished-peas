package diagnostics

import "fmt"

// Subsystem identifies the engine boundary that reported a Failure.
type Subsystem string

const (
	RuntimeSubsystem  Subsystem = "runtime"
	HostSubsystem     Subsystem = "host"
	RendererSubsystem Subsystem = "renderer"
	AssetsSubsystem   Subsystem = "assets"
	FrameSubsystem    Subsystem = "frame"
)

// Recovery gives callers actionable guidance after a Failure. It does not
// retry, recreate, or shut down a subsystem on the caller's behalf.
type Recovery string

const (
	CorrectConfiguration Recovery = "correct configuration"
	CorrectInput         Recovery = "correct input"
	Retry                Recovery = "retry"
	Recreate             Recovery = "recreate subsystem"
	Restart              Recovery = "restart application"
)

// Failure is a structured engine-boundary error. Cause remains available to
// errors.Is and errors.As. Terminal reports whether the operation can continue
// in the current process without the caller first changing state.
type Failure struct {
	Subsystem Subsystem
	Operation string
	Cause     error
	Recovery  Recovery
	Terminal  bool
}

// NewFailure constructs a Failure for an engine boundary. It accepts a nil
// cause for failures detected before an underlying operation is attempted.
func NewFailure(subsystem Subsystem, operation string, cause error, recovery Recovery, terminal bool) *Failure {
	return &Failure{
		Subsystem: subsystem,
		Operation: operation,
		Cause:     cause,
		Recovery:  recovery,
		Terminal:  terminal,
	}
}

func (f *Failure) Error() string {
	if f == nil {
		return "<nil diagnostics failure>"
	}
	subsystem, operation := string(f.Subsystem), f.Operation
	if subsystem == "" {
		subsystem = "engine"
	}
	if operation == "" {
		operation = "operation"
	}
	state := "recoverable"
	if f.Terminal {
		state = "terminal"
	}
	message := fmt.Sprintf("%s %s failed (%s", subsystem, operation, state)
	if f.Recovery != "" {
		message += "; recovery: " + string(f.Recovery)
	}
	message += ")"
	if f.Cause != nil {
		message += ": " + f.Cause.Error()
	}
	return message
}

// Unwrap exposes the underlying cause for errors.Is and errors.As.
func (f *Failure) Unwrap() error {
	if f == nil {
		return nil
	}
	return f.Cause
}
