package sim

// FormRules are gameplay rules, intentionally not merely damage modifiers.
type FormRules struct {
	Radius          float64
	MoveMultiplier  float64
	StaffScale      float64
	DamageMultiplier float64
	HazardImmune    bool
	Untargetable    bool
	CanMove         bool
	CanAttack       bool
	CounterTicks    int
}

func rulesFor(form FormID) FormRules {
	switch form {
	case FormTiger:
		return FormRules{Radius: 12, MoveMultiplier: 0.82, StaffScale: 0.72, DamageMultiplier: 1.55, CanMove: true, CanAttack: true}
	case FormSparrow:
		return FormRules{Radius: 5, MoveMultiplier: 1.65, StaffScale: 0.55, DamageMultiplier: 0.7, HazardImmune: true, CanMove: true, CanAttack: true}
	case FormMantis:
		return FormRules{Radius: 8, MoveMultiplier: 1.1, StaffScale: 0.85, DamageMultiplier: 1, CanMove: true, CanAttack: true, CounterTicks: 7}
	case FormCicada:
		return FormRules{Radius: 4, MoveMultiplier: 1.35, StaffScale: 0.5, DamageMultiplier: 0.55, HazardImmune: true, Untargetable: true, CanMove: true, CanAttack: true}
	case FormGiant:
		return FormRules{Radius: 18, MoveMultiplier: 0.65, StaffScale: 1.55, DamageMultiplier: 1.4, CanMove: true, CanAttack: true}
	case FormStatue:
		return FormRules{Radius: 13, MoveMultiplier: 0, StaffScale: 1, DamageMultiplier: 1, CanMove: false, CanAttack: false}
	default:
		return FormRules{Radius: 9, MoveMultiplier: 1, StaffScale: 1, DamageMultiplier: 1, CanMove: true, CanAttack: true}
	}
}
