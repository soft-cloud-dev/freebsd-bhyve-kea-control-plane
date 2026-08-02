package tomlx

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"unicode"
)

type Document map[string]any

func ParseFile(path string) (Document, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	doc := Document{}
	current := map[string]any(doc)
	scanner := bufio.NewScanner(file)
	for lineNumber := 1; scanner.Scan(); lineNumber++ {
		line := strings.TrimSpace(stripComment(scanner.Text()))
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[[") && strings.HasSuffix(line, "]]") {
			name := strings.TrimSpace(line[2 : len(line)-2])
			if !validKey(name) {
				return nil, fmt.Errorf("line %d: invalid array-table name %q", lineNumber, name)
			}
			entry := map[string]any{}
			existing, exists := doc[name]
			if !exists {
				doc[name] = []map[string]any{entry}
			} else {
				entries, ok := existing.([]map[string]any)
				if !ok {
					return nil, fmt.Errorf("line %d: %q already defined with another type", lineNumber, name)
				}
				doc[name] = append(entries, entry)
			}
			current = entry
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			name := strings.TrimSpace(line[1 : len(line)-1])
			if !validKey(name) {
				return nil, fmt.Errorf("line %d: invalid table name %q", lineNumber, name)
			}
			if _, exists := doc[name]; exists {
				return nil, fmt.Errorf("line %d: duplicate table %q", lineNumber, name)
			}
			table := map[string]any{}
			doc[name] = table
			current = table
			continue
		}

		key, raw, ok := splitAssignment(line)
		if !ok || !validKey(key) {
			return nil, fmt.Errorf("line %d: expected key = value", lineNumber)
		}
		if _, exists := current[key]; exists {
			return nil, fmt.Errorf("line %d: duplicate key %q", lineNumber, key)
		}
		value, err := parseValue(raw)
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", lineNumber, err)
		}
		current[key] = value
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return doc, nil
}

func splitAssignment(line string) (string, string, bool) {
	inString := false
	escaped := false
	for index, char := range line {
		if escaped {
			escaped = false
			continue
		}
		if char == '\\' && inString {
			escaped = true
			continue
		}
		if char == '"' {
			inString = !inString
			continue
		}
		if char == '=' && !inString {
			return strings.TrimSpace(line[:index]), strings.TrimSpace(line[index+1:]), true
		}
	}
	return "", "", false
}

func stripComment(line string) string {
	inString := false
	escaped := false
	for index, char := range line {
		if escaped {
			escaped = false
			continue
		}
		if char == '\\' && inString {
			escaped = true
			continue
		}
		if char == '"' {
			inString = !inString
			continue
		}
		if char == '#' && !inString {
			return line[:index]
		}
	}
	return line
}

func parseValue(raw string) (any, error) {
	if raw == "" {
		return nil, errors.New("empty value")
	}
	if strings.HasPrefix(raw, "\"") {
		value, err := strconv.Unquote(raw)
		if err != nil {
			return nil, fmt.Errorf("invalid quoted string: %w", err)
		}
		return value, nil
	}
	if raw == "true" {
		return true, nil
	}
	if raw == "false" {
		return false, nil
	}
	if strings.HasPrefix(raw, "[") {
		return parseStringArray(raw)
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		return nil, fmt.Errorf("unsupported value %q", raw)
	}
	return value, nil
}

func parseStringArray(raw string) ([]string, error) {
	if !strings.HasSuffix(raw, "]") {
		return nil, errors.New("unterminated array")
	}
	body := strings.TrimSpace(raw[1 : len(raw)-1])
	if body == "" {
		return []string{}, nil
	}
	var values []string
	for len(body) > 0 {
		body = strings.TrimSpace(body)
		if !strings.HasPrefix(body, "\"") {
			return nil, errors.New("only arrays of quoted strings are supported")
		}
		end, err := quotedEnd(body)
		if err != nil {
			return nil, err
		}
		value, err := strconv.Unquote(body[:end+1])
		if err != nil {
			return nil, err
		}
		values = append(values, value)
		body = strings.TrimSpace(body[end+1:])
		if body == "" {
			break
		}
		if body[0] != ',' {
			return nil, errors.New("expected comma in array")
		}
		body = body[1:]
	}
	return values, nil
}

func quotedEnd(value string) (int, error) {
	escaped := false
	for index := 1; index < len(value); index++ {
		if escaped {
			escaped = false
			continue
		}
		if value[index] == '\\' {
			escaped = true
			continue
		}
		if value[index] == '"' {
			return index, nil
		}
	}
	return 0, errors.New("unterminated quoted string")
}

func validKey(value string) bool {
	if value == "" {
		return false
	}
	for _, char := range value {
		if char != '_' && char != '-' && !unicode.IsLetter(char) && !unicode.IsDigit(char) {
			return false
		}
	}
	return true
}
