package bossdsl

import (
	"fmt"
	"strconv"
)

func Validate(file *File) error {
	if file == nil {
		return fmt.Errorf("no boss source")
	}
	if file.Boss.Name == "" {
		return fmt.Errorf("%d:%d: boss name is required", file.Boss.Pos.Line, file.Boss.Pos.Column)
	}
	if len(file.Boss.Phases) == 0 {
		return fmt.Errorf("%d:%d: boss %q has no phases", file.Boss.Pos.Line, file.Boss.Pos.Column, file.Boss.Name)
	}
	seen := make(map[string]bool)
	for _, phase := range file.Boss.Phases {
		if seen[phase.Name] {
			return fmt.Errorf("%d:%d: duplicate phase %q", phase.Pos.Line, phase.Pos.Column, phase.Name)
		}
		seen[phase.Name] = true
		if len(phase.Commands) == 0 {
			return fmt.Errorf("%d:%d: phase %q is empty", phase.Pos.Line, phase.Pos.Column, phase.Name)
		}
		if phase.Condition != nil && phase.Condition.Field != "hp" {
			return fmt.Errorf("%d:%d: unsupported phase condition %q", phase.Condition.Pos.Line, phase.Condition.Pos.Column, phase.Condition.Field)
		}
		if err := validateCommands(phase.Commands); err != nil {
			return err
		}
	}
	return nil
}

func validateCommands(commands []Command) error {
	for _, command := range commands {
		switch command.Name {
		case "wait":
			if len(command.Args) < 1 || !isPositiveNumber(command.Args[0]) {
				return fmt.Errorf("%d:%d: wait requires a positive tick or millisecond value", command.Pos.Line, command.Pos.Column)
			}
		case "attack", "move", "movement", "dash", "spawn", "telegraph", "transition":
			if len(command.Args) == 0 {
				return fmt.Errorf("%d:%d: %s requires an argument", command.Pos.Line, command.Pos.Column, command.Name)
			}
		case "sequence", "parallel":
			if len(command.Args) != 0 || len(command.Commands) == 0 {
				return fmt.Errorf("%d:%d: %s requires a non-empty block", command.Pos.Line, command.Pos.Column, command.Name)
			}
		case "repeat":
			if len(command.Args) > 1 || (len(command.Args) == 1 && !isPositiveNumber(command.Args[0])) || len(command.Commands) == 0 {
				return fmt.Errorf("%d:%d: repeat requires an optional positive count and non-empty block", command.Pos.Line, command.Pos.Column)
			}
		default:
			return fmt.Errorf("%d:%d: unknown command %q", command.Pos.Line, command.Pos.Column, command.Name)
		}
		if len(command.Commands) > 0 {
			if err := validateCommands(command.Commands); err != nil {
				return err
			}
		}
	}
	return nil
}

func isPositiveNumber(value string) bool {
	parsed, err := strconv.Atoi(value)
	return err == nil && parsed > 0
}
