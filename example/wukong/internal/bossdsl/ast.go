// Package bossdsl implements the small authored boss-pattern language.
package bossdsl

type Position struct {
	Offset, Line, Column int
}

type File struct {
	Boss Boss
}

type Boss struct {
	Name   string
	Pos    Position
	Phases []Phase
}

type Phase struct {
	Name      string
	Pos       Position
	Condition *Condition
	Commands  []Command
}

type Condition struct {
	Field    string
	Operator string
	Value    string
	Pos      Position
}

type Command struct {
	Name     string
	Args     []string
	Pos      Position
	Commands []Command
}
