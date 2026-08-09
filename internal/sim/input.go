package sim

// InputFrame is the complete player intent for one deterministic tick.
// Boolean values are edge-detected by World so replay recordings can contain
// the direct controller state rather than UI events.
type InputFrame struct {
	MoveX, MoveY int8
	Attack       bool
	Dodge        bool
	Clone        bool
	Staff        StaffLength
	Transform    FormID
	Restart      bool
	DebugStep    bool
}

type StaffLength uint8

const (
	StaffNone StaffLength = iota // no selection in this input frame
	StaffShort
	StaffMedium
	StaffLong
)

func (s StaffLength) String() string {
	switch s {
	case StaffShort:
		return "short"
	case StaffLong:
		return "long"
	case StaffMedium:
		return "medium"
	default:
		return "none"
	}
}

type FormID uint8

const (
	FormNone FormID = iota // no selection in this input frame
	FormMonkey
	FormTiger
	FormSparrow
	FormMantis
	FormCicada
	FormGiant
	FormStatue
)

func (f FormID) String() string {
	switch f {
	case FormMonkey:
		return "monkey"
	case FormTiger:
		return "tiger"
	case FormSparrow:
		return "sparrow"
	case FormMantis:
		return "mantis"
	case FormCicada:
		return "cicada"
	case FormGiant:
		return "giant"
	case FormStatue:
		return "statue"
	default:
		return "none"
	}
}
