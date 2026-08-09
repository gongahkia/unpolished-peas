package sim

type FormRules struct {
	Radius        float64
	CanCrossWater bool
	MoveSpeed     float64
}

func rulesFor(form FormID) FormRules {
	switch form {
	case FormBird:
		return FormRules{Radius: 5, CanCrossWater: true, MoveSpeed: 5.4}
	case FormTiger:
		return FormRules{Radius: 12, MoveSpeed: 2.5}
	case FormMantis:
		return FormRules{Radius: 8, MoveSpeed: 2.8}
	default:
		return FormRules{Radius: 9, MoveSpeed: 3.45}
	}
}
