package output

import (
	"encoding/json"
	"fmt"
	"io"
)

const SchemaVersion = 1

type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type Envelope struct {
	Schema  int     `json:"schema"`
	Command string  `json:"command"`
	OK      bool    `json:"ok"`
	Data    any     `json:"data,omitempty"`
	Errors  []Error `json:"errors,omitempty"`
}

func WriteJSON(w io.Writer, command string, data any, errs []Error) error {
	envelope := Envelope{
		Schema:  SchemaVersion,
		Command: command,
		OK:      len(errs) == 0,
		Data:    data,
		Errors:  errs,
	}
	encoder := json.NewEncoder(w)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	return encoder.Encode(envelope)
}

func WriteError(w io.Writer, command, code string, err error) error {
	if err == nil {
		return fmt.Errorf("output: nil error")
	}
	return WriteJSON(w, command, nil, []Error{{Code: code, Message: err.Error()}})
}
