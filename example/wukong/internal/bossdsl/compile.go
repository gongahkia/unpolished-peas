package bossdsl

import (
	"fmt"
	"strconv"
)

type Opcode uint8

const (
	OpWait Opcode = iota
	OpAttack
	OpMove
	OpSpawn
	OpTelegraph
	OpTransition
	OpSequence
	OpParallel
	OpRepeat
)

type Instruction struct {
	Op       Opcode
	Args     []string
	Count    int
	Children []Instruction
}

type Program struct {
	BossID string
	Phases []CompiledPhase
}

type CompiledPhase struct {
	Name      string
	Condition *Condition
	Code      []Instruction
}

func Compile(file *File) (*Program, error) {
	if err := Validate(file); err != nil {
		return nil, err
	}
	program := &Program{BossID: file.Boss.Name}
	for _, phase := range file.Boss.Phases {
		code, err := compileCommands(phase.Commands)
		if err != nil {
			return nil, err
		}
		program.Phases = append(program.Phases, CompiledPhase{Name: phase.Name, Condition: phase.Condition, Code: code})
	}
	return program, nil
}

func compileCommands(commands []Command) ([]Instruction, error) {
	result := make([]Instruction, 0, len(commands))
	for _, command := range commands {
		instruction := Instruction{Args: append([]string(nil), command.Args...)}
		switch command.Name {
		case "wait":
			instruction.Op = OpWait
		case "attack":
			instruction.Op = OpAttack
		case "move", "movement", "dash":
			instruction.Op = OpMove
		case "spawn":
			instruction.Op = OpSpawn
		case "telegraph":
			instruction.Op = OpTelegraph
		case "transition":
			instruction.Op = OpTransition
		case "sequence":
			instruction.Op = OpSequence
		case "parallel":
			instruction.Op = OpParallel
		case "repeat":
			instruction.Op = OpRepeat
			instruction.Count = 1
			if len(command.Args) == 1 {
				count, err := strconv.Atoi(command.Args[0])
				if err != nil {
					return nil, fmt.Errorf("%d:%d: repeat count must be an integer", command.Pos.Line, command.Pos.Column)
				}
				instruction.Count = count
			}
		}
		var err error
		instruction.Children, err = compileCommands(command.Commands)
		if err != nil {
			return nil, err
		}
		result = append(result, instruction)
	}
	return result, nil
}
