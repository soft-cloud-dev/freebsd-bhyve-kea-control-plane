package config

import (
	"fmt"
	"sort"
	"strings"
)

func rejectUnknown(values map[string]any, allowed ...string) error {
	set := make(map[string]struct{}, len(allowed))
	for _, key := range allowed {
		set[key] = struct{}{}
	}
	var unknown []string
	for key := range values {
		if _, ok := set[key]; !ok {
			unknown = append(unknown, key)
		}
	}
	if len(unknown) == 0 {
		return nil
	}
	sort.Strings(unknown)
	return fmt.Errorf("unknown keys: %s", strings.Join(unknown, ", "))
}

func requiredString(values map[string]any, key string) (string, error) {
	value, exists := values[key]
	if !exists {
		return "", fmt.Errorf("missing key %q", key)
	}
	result, ok := value.(string)
	if !ok {
		return "", fmt.Errorf("%s must be a string", key)
	}
	return result, nil
}

func optionalString(values map[string]any, key string) (string, error) {
	value, exists := values[key]
	if !exists {
		return "", nil
	}
	result, ok := value.(string)
	if !ok {
		return "", fmt.Errorf("%s must be a string", key)
	}
	return result, nil
}

func requiredInt(values map[string]any, key string) (int, error) {
	value, exists := values[key]
	if !exists {
		return 0, fmt.Errorf("missing key %q", key)
	}
	result, ok := value.(int)
	if !ok {
		return 0, fmt.Errorf("%s must be an integer", key)
	}
	return result, nil
}

func optionalInt(values map[string]any, key string) (int, error) {
	value, exists := values[key]
	if !exists {
		return 0, nil
	}
	result, ok := value.(int)
	if !ok {
		return 0, fmt.Errorf("%s must be an integer", key)
	}
	return result, nil
}

func requiredBool(values map[string]any, key string) (bool, error) {
	value, exists := values[key]
	if !exists {
		return false, fmt.Errorf("missing key %q", key)
	}
	result, ok := value.(bool)
	if !ok {
		return false, fmt.Errorf("%s must be a boolean", key)
	}
	return result, nil
}

func requiredStrings(values map[string]any, key string) ([]string, error) {
	value, exists := values[key]
	if !exists {
		return nil, fmt.Errorf("missing key %q", key)
	}
	result, ok := value.([]string)
	if !ok {
		return nil, fmt.Errorf("%s must be an array of strings", key)
	}
	return result, nil
}

func requiredTable(values map[string]any, key string) (map[string]any, error) {
	value, exists := values[key]
	if !exists {
		return nil, fmt.Errorf("missing table %q", key)
	}
	result, ok := value.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("%s must be a table", key)
	}
	return result, nil
}

func requiredArrayTables(values map[string]any, key string) ([]map[string]any, error) {
	value, exists := values[key]
	if !exists {
		return nil, fmt.Errorf("missing array table %q", key)
	}
	result, ok := value.([]map[string]any)
	if !ok {
		return nil, fmt.Errorf("%s must be an array of tables", key)
	}
	return result, nil
}
