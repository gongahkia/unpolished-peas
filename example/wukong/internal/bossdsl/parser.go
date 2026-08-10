package bossdsl

import "fmt"

type parser struct {
	tokens []token
	index  int
}

func Parse(source string) (*File, error) {
	tokens, err := lex(source)
	if err != nil {
		return nil, err
	}
	p := parser{tokens: tokens}
	if err := p.expectWord("boss"); err != nil {
		return nil, err
	}
	name, err := p.expect(tokenIdentifier, "boss name")
	if err != nil {
		return nil, err
	}
	if _, err := p.expect(tokenLBrace, "{"); err != nil {
		return nil, err
	}
	file := &File{Boss: Boss{Name: name.text, Pos: name.pos}}
	for p.peek().kind != tokenRBrace && p.peek().kind != tokenEOF {
		phase, err := p.parsePhase()
		if err != nil {
			return nil, err
		}
		file.Boss.Phases = append(file.Boss.Phases, phase)
	}
	if _, err := p.expect(tokenRBrace, "}"); err != nil {
		return nil, err
	}
	if p.peek().kind != tokenEOF {
		return nil, p.errorf(p.peek(), "unexpected token after boss block")
	}
	return file, nil
}

func (p *parser) parsePhase() (Phase, error) {
	if err := p.expectWord("phase"); err != nil {
		return Phase{}, err
	}
	name, err := p.expect(tokenIdentifier, "phase name")
	if err != nil {
		return Phase{}, err
	}
	phase := Phase{Name: name.text, Pos: name.pos}
	if p.peek().kind == tokenIdentifier && p.peek().text == "when" {
		p.advance()
		field, err := p.expect(tokenIdentifier, "condition field")
		if err != nil {
			return Phase{}, err
		}
		operator := p.advance()
		if operator.kind != tokenLess && operator.kind != tokenGreater && operator.kind != tokenEqual {
			return Phase{}, p.errorf(operator, "expected condition operator")
		}
		value := p.advance()
		if value.kind != tokenNumber && value.kind != tokenIdentifier {
			return Phase{}, p.errorf(value, "expected condition value")
		}
		phase.Condition = &Condition{Field: field.text, Operator: operator.text, Value: value.text, Pos: field.pos}
	}
	commands, err := p.parseBlock()
	if err != nil {
		return Phase{}, err
	}
	phase.Commands = commands
	return phase, nil
}

func (p *parser) parseBlock() ([]Command, error) {
	if _, err := p.expect(tokenLBrace, "{"); err != nil {
		return nil, err
	}
	var commands []Command
	for p.peek().kind != tokenRBrace && p.peek().kind != tokenEOF {
		command, err := p.parseCommand()
		if err != nil {
			return nil, err
		}
		commands = append(commands, command)
	}
	if _, err := p.expect(tokenRBrace, "}"); err != nil {
		return nil, err
	}
	return commands, nil
}

func (p *parser) parseCommand() (Command, error) {
	name, err := p.expect(tokenIdentifier, "command")
	if err != nil {
		return Command{}, err
	}
	command := Command{Name: name.text, Pos: name.pos}
	for p.peek().kind != tokenSemicolon && p.peek().kind != tokenLBrace && p.peek().kind != tokenEOF && p.peek().kind != tokenRBrace {
		argument := p.advance()
		if argument.kind != tokenIdentifier && argument.kind != tokenNumber && argument.kind != tokenLess && argument.kind != tokenGreater && argument.kind != tokenEqual {
			return Command{}, p.errorf(argument, "invalid command argument")
		}
		command.Args = append(command.Args, argument.text)
	}
	if p.peek().kind == tokenLBrace {
		children, err := p.parseBlock()
		if err != nil {
			return Command{}, err
		}
		command.Commands = children
		return command, nil
	}
	if _, err := p.expect(tokenSemicolon, ";"); err != nil {
		return Command{}, err
	}
	return command, nil
}

func (p *parser) peek() token { return p.tokens[p.index] }

func (p *parser) advance() token {
	current := p.peek()
	if p.index < len(p.tokens)-1 {
		p.index++
	}
	return current
}

func (p *parser) expect(kind tokenKind, label string) (token, error) {
	current := p.advance()
	if current.kind != kind {
		return token{}, p.errorf(current, "expected %s", label)
	}
	return current, nil
}

func (p *parser) expectWord(word string) error {
	current := p.advance()
	if current.kind != tokenIdentifier || current.text != word {
		return p.errorf(current, "expected %q", word)
	}
	return nil
}

func (p *parser) errorf(current token, format string, args ...any) error {
	return fmt.Errorf("%d:%d: %s", current.pos.Line, current.pos.Column, fmt.Sprintf(format, args...))
}
