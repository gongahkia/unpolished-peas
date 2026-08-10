package bossdsl

import (
	"fmt"
	"unicode"
)

type tokenKind uint8

const (
	tokenEOF tokenKind = iota
	tokenIdentifier
	tokenNumber
	tokenLBrace
	tokenRBrace
	tokenSemicolon
	tokenLess
	tokenGreater
	tokenEqual
)

type token struct {
	kind tokenKind
	text string
	pos  Position
}

type lexer struct {
	source       string
	offset       int
	line, column int
}

func lex(source string) ([]token, error) {
	l := lexer{source: source, line: 1, column: 1}
	var tokens []token
	for {
		token, err := l.next()
		if err != nil {
			return nil, err
		}
		tokens = append(tokens, token)
		if token.kind == tokenEOF {
			return tokens, nil
		}
	}
}

func (l *lexer) next() (token, error) {
	l.skipSpaceAndComments()
	position := Position{Offset: l.offset, Line: l.line, Column: l.column}
	if l.offset >= len(l.source) {
		return token{kind: tokenEOF, pos: position}, nil
	}
	r := rune(l.source[l.offset])
	switch r {
	case '{':
		l.advance()
		return token{kind: tokenLBrace, text: "{", pos: position}, nil
	case '}':
		l.advance()
		return token{kind: tokenRBrace, text: "}", pos: position}, nil
	case ';':
		l.advance()
		return token{kind: tokenSemicolon, text: ";", pos: position}, nil
	case '<':
		l.advance()
		return token{kind: tokenLess, text: "<", pos: position}, nil
	case '>':
		l.advance()
		return token{kind: tokenGreater, text: ">", pos: position}, nil
	case '=':
		l.advance()
		return token{kind: tokenEqual, text: "=", pos: position}, nil
	}
	if unicode.IsLetter(r) || r == '_' {
		start := l.offset
		for l.offset < len(l.source) {
			part := rune(l.source[l.offset])
			if !unicode.IsLetter(part) && !unicode.IsDigit(part) && part != '_' && part != '-' {
				break
			}
			l.advance()
		}
		return token{kind: tokenIdentifier, text: l.source[start:l.offset], pos: position}, nil
	}
	if unicode.IsDigit(r) {
		start := l.offset
		for l.offset < len(l.source) && unicode.IsDigit(rune(l.source[l.offset])) {
			l.advance()
		}
		return token{kind: tokenNumber, text: l.source[start:l.offset], pos: position}, nil
	}
	return token{}, fmt.Errorf("%d:%d: unexpected character %q", position.Line, position.Column, r)
}

func (l *lexer) skipSpaceAndComments() {
	for l.offset < len(l.source) {
		if l.source[l.offset] == '/' && l.offset+1 < len(l.source) && l.source[l.offset+1] == '/' {
			for l.offset < len(l.source) && l.source[l.offset] != '\n' {
				l.advance()
			}
			continue
		}
		if !unicode.IsSpace(rune(l.source[l.offset])) {
			return
		}
		l.advance()
	}
}

func (l *lexer) advance() {
	if l.offset >= len(l.source) {
		return
	}
	if l.source[l.offset] == '\n' {
		l.line++
		l.column = 1
	} else {
		l.column++
	}
	l.offset++
}
