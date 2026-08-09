package sim

// InputFrame is the deterministic intent sampled for one simulation tick.
// Movement and Aim deliberately remain separate all the way into combat.
type InputFrame struct {
	MoveX      int8
	AimX, AimY int8
	Jump       bool
	Attack     bool
	Dodge      bool
	Clone      bool
	Staff      StaffLength
	Transform  FormID
	Restart    bool
	DebugStep  bool
}

type StaffLength uint8

const (
	StaffNone StaffLength = iota
	StaffShort
	StaffMedium
	StaffLong
)

func (s StaffLength) String() string {
	switch s {
	case StaffShort:
		return "short"
	case StaffMedium:
		return "medium"
	case StaffLong:
		return "long"
	default:
		return "none"
	}
}

type FormID uint8

const (
	FormNone FormID = iota
	FormMonkey
	FormBird
	FormTiger
	FormMantis
)

func (f FormID) String() string {
	switch f {
	case FormBird:
		return "bird"
	case FormTiger:
		return "tiger"
	case FormMantis:
		return "mantis"
	case FormMonkey:
		return "monkey"
	default:
		return "none"
	}
}
