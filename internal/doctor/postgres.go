package doctor

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type postgresTarget struct {
	Network  string
	Address  string
	User     string
	Database string
}

func probePostgres(ctx context.Context, siteDSN string) Check {
	target, err := parsePostgresTarget(siteDSN)
	if err != nil {
		return Check{Name: "live.postgresql", Required: true, Status: Fail, Detail: err.Error()}
	}
	dialer := net.Dialer{Timeout: 5 * time.Second}
	connection, err := dialer.DialContext(ctx, target.Network, target.Address)
	if err != nil {
		return Check{Name: "live.postgresql", Required: true, Status: Fail, Detail: err.Error()}
	}
	defer connection.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = connection.SetDeadline(deadline)
	}
	if err := postgresStartup(connection, target); err != nil {
		return Check{Name: "live.postgresql", Required: true, Status: Fail, Detail: err.Error()}
	}
	if err := postgresQueryOne(connection); err != nil {
		return Check{Name: "live.postgresql", Required: true, Status: Fail, Detail: err.Error()}
	}
	return Check{Name: "live.postgresql", Required: true, Status: Pass, Detail: "query succeeded"}
}

func parsePostgresTarget(dsn string) (postgresTarget, error) {
	values := map[string]string{}
	for _, field := range strings.Fields(dsn) {
		key, value, ok := strings.Cut(field, "=")
		if !ok || key == "" || value == "" {
			return postgresTarget{}, fmt.Errorf("database.dsn contains unsupported field %q", field)
		}
		values[key] = strings.Trim(value, "'\"")
	}
	user := values["user"]
	database := values["dbname"]
	if user == "" || database == "" {
		return postgresTarget{}, errors.New("database.dsn must define user and dbname")
	}
	port := values["port"]
	if port == "" {
		port = "5432"
	}
	if _, err := strconv.ParseUint(port, 10, 16); err != nil {
		return postgresTarget{}, errors.New("database.dsn port must be numeric")
	}
	host := values["host"]
	if host == "" {
		host = "/var/run/postgresql"
	}
	if filepath.IsAbs(host) {
		return postgresTarget{Network: "unix", Address: filepath.Join(host, ".s.PGSQL."+port), User: user, Database: database}, nil
	}
	return postgresTarget{Network: "tcp", Address: net.JoinHostPort(host, port), User: user, Database: database}, nil
}

func postgresStartup(connection net.Conn, target postgresTarget) error {
	payload := make([]byte, 4)
	binary.BigEndian.PutUint32(payload, 196608)
	payload = appendCString(payload, "user")
	payload = appendCString(payload, target.User)
	payload = appendCString(payload, "database")
	payload = appendCString(payload, target.Database)
	payload = append(payload, 0)
	message := make([]byte, 4+len(payload))
	binary.BigEndian.PutUint32(message, uint32(len(message)))
	copy(message[4:], payload)
	if _, err := connection.Write(message); err != nil {
		return fmt.Errorf("postgres startup write: %w", err)
	}
	reader := bufio.NewReader(connection)
	for {
		messageType, body, err := readPostgresMessage(reader)
		if err != nil {
			return fmt.Errorf("postgres startup read: %w", err)
		}
		switch messageType {
		case 'R':
			if len(body) < 4 {
				return errors.New("postgres returned malformed authentication request")
			}
			method := binary.BigEndian.Uint32(body[:4])
			if method != 0 {
				return fmt.Errorf("postgres authentication method %d is unsupported; configure local peer or trust authentication", method)
			}
		case 'E':
			return fmt.Errorf("postgres startup: %s", postgresError(body))
		case 'Z':
			return nil
		}
	}
}

func postgresQueryOne(connection net.Conn) error {
	query := append([]byte("select 1"), 0)
	message := make([]byte, 5+len(query))
	message[0] = 'Q'
	binary.BigEndian.PutUint32(message[1:5], uint32(4+len(query)))
	copy(message[5:], query)
	if _, err := connection.Write(message); err != nil {
		return fmt.Errorf("postgres query write: %w", err)
	}
	reader := bufio.NewReader(connection)
	seenOne := false
	for {
		messageType, body, err := readPostgresMessage(reader)
		if err != nil {
			return fmt.Errorf("postgres query read: %w", err)
		}
		switch messageType {
		case 'D':
			value, err := firstDataRowValue(body)
			if err != nil {
				return err
			}
			seenOne = value == "1"
		case 'E':
			return fmt.Errorf("postgres query: %s", postgresError(body))
		case 'Z':
			if !seenOne {
				return errors.New("postgres query returned an unexpected result")
			}
			return nil
		}
	}
}

func readPostgresMessage(reader *bufio.Reader) (byte, []byte, error) {
	messageType, err := reader.ReadByte()
	if err != nil {
		return 0, nil, err
	}
	lengthBytes := make([]byte, 4)
	if _, err := io.ReadFull(reader, lengthBytes); err != nil {
		return 0, nil, err
	}
	length := binary.BigEndian.Uint32(lengthBytes)
	if length < 4 || length > 16<<20 {
		return 0, nil, fmt.Errorf("invalid message length %d", length)
	}
	body := make([]byte, length-4)
	if _, err := io.ReadFull(reader, body); err != nil {
		return 0, nil, err
	}
	return messageType, body, nil
}

func firstDataRowValue(body []byte) (string, error) {
	if len(body) < 6 || binary.BigEndian.Uint16(body[:2]) < 1 {
		return "", errors.New("postgres returned malformed data row")
	}
	length := int32(binary.BigEndian.Uint32(body[2:6]))
	if length < 0 {
		return "", errors.New("postgres returned NULL for select 1")
	}
	if int(length) > len(body)-6 {
		return "", errors.New("postgres returned truncated data row")
	}
	return string(body[6 : 6+length]), nil
}

func postgresError(body []byte) string {
	fields := map[byte]string{}
	for len(body) > 1 && body[0] != 0 {
		fieldType := body[0]
		body = body[1:]
		end := strings.IndexByte(string(body), 0)
		if end < 0 {
			break
		}
		fields[fieldType] = string(body[:end])
		body = body[end+1:]
	}
	if message := fields['M']; message != "" {
		return message
	}
	return "unknown PostgreSQL error"
}

func appendCString(buffer []byte, value string) []byte {
	buffer = append(buffer, value...)
	return append(buffer, 0)
}
