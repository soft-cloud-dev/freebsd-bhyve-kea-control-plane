package execution

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/planner"
	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/state"
)

type CommandRunner interface {
	Run(context.Context, string, ...string) ([]byte, error)
}

type OSRunner struct{}

func (OSRunner) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, name, args...)
	output, err := command.CombinedOutput()
	if err != nil {
		return output, fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return output, nil
}

type SystemDriver struct {
	Runner CommandRunner
	Client *http.Client
}

func NewSystemDriver() *SystemDriver {
	return &SystemDriver{Runner: OSRunner{}, Client: &http.Client{Timeout: 30 * time.Second}}
}

func (d *SystemDriver) Ensure(ctx context.Context, input planner.StepInput) (Result, error) {
	if d.Runner == nil {
		d.Runner = OSRunner{}
	}
	if d.Client == nil {
		d.Client = &http.Client{Timeout: 30 * time.Second}
	}
	switch input.Driver + "/" + input.Action {
	case "image/ensure-verified":
		return d.ensureImage(ctx, input)
	case "zfs/ensure-storage":
		return d.ensureStorage(ctx, input)
	case "zfs/ensure-absent":
		return d.ensureStorageAbsent(ctx, input)
	case "cloudinit/ensure-seed":
		return d.ensureSeed(ctx, input)
	case "cloudinit/ensure-absent":
		return d.ensureSeedAbsent(input)
	case "vmbhyve/ensure-definition":
		return d.ensureVMDefinition(input)
	case "vmbhyve/ensure-config":
		return d.ensureVMConfig(input)
	case "vmbhyve/ensure-power-state":
		return d.ensurePower(ctx, input, input.Specification.DesiredPower)
	case "vmbhyve/ensure-stopped":
		return d.ensurePower(ctx, input, "stopped")
	case "vmbhyve/ensure-absent":
		return d.ensureVMAbsent(ctx, input)
	case "kea/ensure-reservation":
		return d.ensureKeaReservation(ctx, input)
	case "kea/ensure-absent":
		return d.ensureKeaAbsent(ctx, input)
	case "pf/ensure-rules":
		return d.ensurePFRules(ctx, input)
	case "pf/ensure-absent":
		return d.ensurePFAbsent(ctx, input)
	case "observer/observe-all":
		return d.observe(ctx, input, false)
	case "observer/observe-absent":
		return d.observe(ctx, input, true)
	default:
		return Result{}, fmt.Errorf("%w: unsupported driver action %s/%s", state.ErrBlocked, input.Driver, input.Action)
	}
}

func (d *SystemDriver) ensureImage(ctx context.Context, input planner.StepInput) (Result, error) {
	if input.Image.CompressedSHA256 == strings.Repeat("0", 64) {
		return Result{}, fmt.Errorf("%w: image digest is the all-zero validation sentinel", state.ErrBlocked)
	}
	imageDir := filepath.Join(input.Host.VMRoot, ".bkcp", "images")
	rawPath := filepath.Join(imageDir, input.Image.Name+".raw")
	markerPath := rawPath + ".verified.json"
	var marker map[string]string
	if encoded, err := os.ReadFile(markerPath); err == nil && json.Unmarshal(encoded, &marker) == nil {
		if marker["compressed_sha256"] == input.Image.CompressedSHA256 {
			if digest, err := fileSHA256(rawPath); err == nil && digest == marker["raw_sha256"] {
				return Result{Postcondition: marker}, nil
			}
		}
	}
	if err := os.MkdirAll(imageDir, 0o755); err != nil {
		return Result{}, err
	}
	tempDir, err := os.MkdirTemp(imageDir, ".image-")
	if err != nil {
		return Result{}, err
	}
	defer os.RemoveAll(tempDir)
	compressedPath := filepath.Join(tempDir, "image.download")
	if err := d.download(ctx, input.Image.URL, compressedPath); err != nil {
		return Result{}, err
	}
	compressedDigest, err := fileSHA256(compressedPath)
	if err != nil {
		return Result{}, err
	}
	if compressedDigest != strings.ToLower(input.Image.CompressedSHA256) {
		return Result{}, fmt.Errorf("%w: image SHA-256 expected %s got %s", state.ErrBlocked, input.Image.CompressedSHA256, compressedDigest)
	}
	rawTemp := filepath.Join(tempDir, "image.raw")
	switch input.Image.Format {
	case "raw.xz":
		if err := commandToFile(ctx, rawTemp, "unxz", "-c", compressedPath); err != nil {
			return Result{}, err
		}
	case "raw":
		if err := copyFile(compressedPath, rawTemp, 0o644); err != nil {
			return Result{}, err
		}
	default:
		return Result{}, fmt.Errorf("%w: unsupported image format %q", state.ErrBlocked, input.Image.Format)
	}
	rawDigest, err := fileSHA256(rawTemp)
	if err != nil {
		return Result{}, err
	}
	if err := os.Chmod(rawTemp, 0o644); err != nil {
		return Result{}, err
	}
	if err := os.Rename(rawTemp, rawPath); err != nil {
		return Result{}, err
	}
	marker = map[string]string{"path": rawPath, "url": input.Image.URL, "compressed_sha256": compressedDigest, "raw_sha256": rawDigest}
	if err := writeJSONAtomic(markerPath, marker, 0o644); err != nil {
		return Result{}, err
	}
	return Result{Postcondition: marker}, nil
}

func (d *SystemDriver) ensureStorage(ctx context.Context, input planner.StepInput) (Result, error) {
	datasetCreated := false
	if _, err := d.Runner.Run(ctx, "zfs", "list", "-H", "-o", "name", input.Allocation.DatasetName); err != nil {
		if _, createErr := d.Runner.Run(ctx, "zfs", "create", "-p", input.Allocation.DatasetName); createErr != nil {
			return Result{}, createErr
		}
		datasetCreated = true
	}
	zvolCreated := false
	if _, err := d.Runner.Run(ctx, "zfs", "list", "-H", "-o", "name", input.Allocation.ZvolName); err != nil {
		size := strconv.Itoa(input.Specification.DiskGB) + "G"
		if _, createErr := d.Runner.Run(ctx, "zfs", "create", "-V", size, input.Allocation.ZvolName); createErr != nil {
			return Result{}, createErr
		}
		zvolCreated = true
	}
	if zvolCreated {
		rawPath := filepath.Join(input.Host.VMRoot, ".bkcp", "images", input.Image.Name+".raw")
		if _, err := os.Stat(rawPath); err != nil {
			return Result{}, fmt.Errorf("verified raw image unavailable: %w", err)
		}
		device := "/dev/zvol/" + input.Allocation.ZvolName
		if _, err := d.Runner.Run(ctx, "dd", "if="+rawPath, "of="+device, "bs=1M", "status=none"); err != nil {
			return Result{}, err
		}
	}
	return Result{Postcondition: map[string]any{"dataset": input.Allocation.DatasetName, "zvol": input.Allocation.ZvolName, "dataset_created": datasetCreated, "zvol_created": zvolCreated}}, nil
}

func (d *SystemDriver) ensureStorageAbsent(ctx context.Context, input planner.StepInput) (Result, error) {
	if !input.DestroyStorage {
		return Result{}, fmt.Errorf("%w: storage destruction was not authorized", state.ErrBlocked)
	}
	if _, err := d.Runner.Run(ctx, "zfs", "list", "-H", "-o", "name", input.Allocation.DatasetName); err == nil {
		if _, err := d.Runner.Run(ctx, "zfs", "destroy", "-r", input.Allocation.DatasetName); err != nil {
			return Result{}, err
		}
	}
	return Result{Postcondition: map[string]any{"dataset": input.Allocation.DatasetName, "absent": true}}, nil
}

func (d *SystemDriver) ensureSeed(ctx context.Context, input planner.StepInput) (Result, error) {
	guestDir := filepath.Join(input.Host.VMRoot, input.Resource)
	seedPath := filepath.Join(guestDir, "seed.iso")
	if digest, err := fileSHA256(seedPath); err == nil {
		return Result{Postcondition: map[string]any{"path": seedPath, "sha256": digest}}, nil
	}
	if err := os.MkdirAll(guestDir, 0o750); err != nil {
		return Result{}, err
	}
	tempDir, err := os.MkdirTemp(guestDir, ".seed-")
	if err != nil {
		return Result{}, err
	}
	defer os.RemoveAll(tempDir)
	meta := fmt.Sprintf("instance-id: %s\nlocal-hostname: %s\n", input.Resource, input.Resource)
	user := "#cloud-config\n"
	if input.Specification.SSHPublicKeyFile != "" {
		keyBytes, err := os.ReadFile(input.Specification.SSHPublicKeyFile)
		if err != nil {
			return Result{}, fmt.Errorf("read SSH public key: %w", err)
		}
		key := strings.TrimSpace(string(keyBytes))
		if !strings.HasPrefix(key, "ssh-ed25519 ") && !strings.HasPrefix(key, "sk-ssh-ed25519@openssh.com ") {
			return Result{}, fmt.Errorf("%w: SSH public key must be Ed25519", state.ErrBlocked)
		}
		user += fmt.Sprintf("users:\n  - default\n  - name: '%s'\n    lock_passwd: true\n    shell: /bin/sh\n    ssh_authorized_keys:\n      - '%s'\n", yamlQuote(input.Specification.Owner), yamlQuote(key))
	}
	user += fmt.Sprintf("write_files:\n  - path: /etc/bkcp-profile\n    permissions: '0644'\n    content: '%s'\n", yamlQuote(input.Specification.Profile))
	if err := os.WriteFile(filepath.Join(tempDir, "meta-data"), []byte(meta), 0o600); err != nil {
		return Result{}, err
	}
	if err := os.WriteFile(filepath.Join(tempDir, "user-data"), []byte(user), 0o600); err != nil {
		return Result{}, err
	}
	seedTemp := filepath.Join(guestDir, ".seed.iso.tmp")
	_ = os.Remove(seedTemp)
	command := exec.CommandContext(ctx, "makefs", "-t", "cd9660", "-o", "rockridge,label=cidata", seedTemp, tempDir)
	if output, err := command.CombinedOutput(); err != nil {
		return Result{}, fmt.Errorf("makefs seed: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if err := os.Chmod(seedTemp, 0o600); err != nil {
		return Result{}, err
	}
	if err := os.Rename(seedTemp, seedPath); err != nil {
		return Result{}, err
	}
	digest, err := fileSHA256(seedPath)
	if err != nil {
		return Result{}, err
	}
	return Result{Postcondition: map[string]any{"path": seedPath, "sha256": digest}}, nil
}

func (d *SystemDriver) ensureSeedAbsent(input planner.StepInput) (Result, error) {
	seedPath := filepath.Join(input.Host.VMRoot, input.Resource, "seed.iso")
	if err := os.Remove(seedPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return Result{}, err
	}
	return Result{Postcondition: map[string]any{"path": seedPath, "absent": true}}, nil
}

func (d *SystemDriver) ensureVMDefinition(input planner.StepInput) (Result, error) {
	guestDir := filepath.Join(input.Host.VMRoot, input.Resource)
	if err := os.MkdirAll(guestDir, 0o750); err != nil {
		return Result{}, err
	}
	return Result{Postcondition: map[string]any{"guest_dir": guestDir}}, nil
}

func (d *SystemDriver) ensureVMConfig(input planner.StepInput) (Result, error) {
	guestDir := filepath.Join(input.Host.VMRoot, input.Resource)
	configPath := filepath.Join(guestDir, input.Resource+".conf")
	contents := fmt.Sprintf("guest=\"freebsd\"\nloader=\"%s\"\ncpu=\"%d\"\nmemory=\"%dM\"\nnetwork0_type=\"virtio-net\"\nnetwork0_switch=\"%s\"\nnetwork0_mac=\"%s\"\ndisk0_type=\"virtio-blk\"\ndisk0_dev=\"custom\"\ndisk0_name=\"/dev/zvol/%s\"\ndisk1_type=\"ahci-cd\"\ndisk1_dev=\"file\"\ndisk1_name=\"seed.iso\"\nutctime=\"yes\"\nvirt_random=\"yes\"\n", input.Image.Loader, input.Specification.CPUs, input.Specification.MemoryMB, input.Host.VMBridge, input.Allocation.MACAddress, input.Allocation.ZvolName)
	if err := writeAtomic(configPath, []byte(contents), 0o600); err != nil {
		return Result{}, err
	}
	digest := sha256.Sum256([]byte(contents))
	return Result{Postcondition: map[string]any{"path": configPath, "sha256": hex.EncodeToString(digest[:])}}, nil
}

func (d *SystemDriver) ensurePower(ctx context.Context, input planner.StepInput, desired string) (Result, error) {
	exists, running, err := d.vmState(ctx, input.Resource)
	if err != nil {
		return Result{}, err
	}
	if !exists {
		return Result{}, fmt.Errorf("%w: vm-bhyve does not discover %s", state.ErrBlocked, input.Resource)
	}
	if desired == "running" && !running {
		if _, err := d.Runner.Run(ctx, "vm", "start", input.Resource); err != nil {
			return Result{}, err
		}
		running = true
	}
	if desired == "stopped" && running {
		if _, err := d.Runner.Run(ctx, "vm", "stop", input.Resource); err != nil {
			return Result{}, err
		}
		running = false
	}
	return Result{Postcondition: map[string]any{"vm": input.Resource, "power": map[bool]string{true: "running", false: "stopped"}[running]}}, nil
}

func (d *SystemDriver) ensureVMAbsent(ctx context.Context, input planner.StepInput) (Result, error) {
	exists, running, err := d.vmState(ctx, input.Resource)
	if err != nil {
		return Result{}, err
	}
	if exists {
		if running {
			if _, err := d.Runner.Run(ctx, "vm", "stop", input.Resource); err != nil {
				return Result{}, err
			}
		}
		if _, err := d.Runner.Run(ctx, "vm", "destroy", "-f", input.Resource); err != nil {
			if removeErr := os.RemoveAll(filepath.Join(input.Host.VMRoot, input.Resource)); removeErr != nil {
				return Result{}, err
			}
		}
	}
	return Result{Postcondition: map[string]any{"vm": input.Resource, "absent": true}}, nil
}

func (d *SystemDriver) ensureKeaReservation(ctx context.Context, input planner.StepInput) (Result, error) {
	present, _, err := d.keaReservation(ctx, input)
	if err != nil {
		return Result{}, err
	}
	if !present {
		arguments := map[string]any{"operation-target": "database", "reservation": map[string]any{"subnet-id": input.Allocation.KeaSubnetID, "hw-address": input.Allocation.MACAddress, "ip-address": input.Allocation.IPAddress, "hostname": input.Resource}}
		if _, err := d.keaRequest(ctx, input, "reservation-add", arguments); err != nil {
			return Result{}, err
		}
	}
	present, response, err := d.keaReservation(ctx, input)
	if err != nil || !present {
		if err == nil {
			err = errors.New("reservation postcondition is absent")
		}
		return Result{}, err
	}
	return Result{Postcondition: map[string]any{"reservation": response}}, nil
}

func (d *SystemDriver) ensureKeaAbsent(ctx context.Context, input planner.StepInput) (Result, error) {
	present, _, err := d.keaReservation(ctx, input)
	if err != nil {
		return Result{}, err
	}
	if present {
		arguments := map[string]any{"operation-target": "database", "subnet-id": input.Allocation.KeaSubnetID, "identifier-type": "hw-address", "identifier": input.Allocation.MACAddress}
		if _, err := d.keaRequest(ctx, input, "reservation-del", arguments); err != nil {
			return Result{}, err
		}
	}
	return Result{Postcondition: map[string]any{"reservation": input.Allocation.MACAddress, "absent": true}}, nil
}

func (d *SystemDriver) ensurePFRules(ctx context.Context, input planner.StepInput) (Result, error) {
	if !input.Network.ManageAnchor {
		return Result{Skipped: true, Postcondition: map[string]any{"managed": false}}, nil
	}
	anchor := input.Network.PFAnchor + "/" + input.Resource
	rules := fmt.Sprintf("pass in quick on %s from %s to any keep state\npass out quick on %s to %s keep state\n", input.Host.VMBridge, input.Allocation.IPAddress, input.Host.VMBridge, input.Allocation.IPAddress)
	temp, err := os.CreateTemp("", "bkcp-pf-*.conf")
	if err != nil {
		return Result{}, err
	}
	path := temp.Name()
	defer os.Remove(path)
	if _, err := temp.WriteString(rules); err != nil {
		temp.Close()
		return Result{}, err
	}
	if err := temp.Close(); err != nil {
		return Result{}, err
	}
	if _, err := d.Runner.Run(ctx, "pfctl", "-n", "-a", anchor, "-f", path); err != nil {
		return Result{}, err
	}
	if _, err := d.Runner.Run(ctx, "pfctl", "-a", anchor, "-f", path); err != nil {
		return Result{}, err
	}
	digest := sha256.Sum256([]byte(rules))
	return Result{Postcondition: map[string]any{"anchor": anchor, "sha256": hex.EncodeToString(digest[:])}}, nil
}

func (d *SystemDriver) ensurePFAbsent(ctx context.Context, input planner.StepInput) (Result, error) {
	if !input.Network.ManageAnchor {
		return Result{Skipped: true, Postcondition: map[string]any{"managed": false}}, nil
	}
	anchor := input.Network.PFAnchor + "/" + input.Resource
	if _, err := d.Runner.Run(ctx, "pfctl", "-a", anchor, "-F", "rules"); err != nil {
		return Result{}, err
	}
	return Result{Postcondition: map[string]any{"anchor": anchor, "absent": true}}, nil
}

func (d *SystemDriver) observe(ctx context.Context, input planner.StepInput, expectAbsent bool) (Result, error) {
	vmExists, running, vmErr := d.vmState(ctx, input.Resource)
	storageExists := false
	storageErr := error(nil)
	if _, err := d.Runner.Run(ctx, "zfs", "list", "-H", "-o", "name", input.Allocation.ZvolName); err == nil {
		storageExists = true
	} else {
		storageErr = err
	}
	keaExists, keaResponse, keaErr := d.keaReservation(ctx, input)
	seedPath := filepath.Join(input.Host.VMRoot, input.Resource, "seed.iso")
	_, seedErr := os.Stat(seedPath)
	seedExists := seedErr == nil
	vmState := presence(vmExists, vmErr)
	storageState := presence(storageExists, storageErr)
	keaState := presence(keaExists, keaErr)
	seedState := presence(seedExists, seedErr)
	power := "absent"
	if vmErr != nil {
		power = "unavailable"
	} else if vmExists {
		if running {
			power = "running"
		} else {
			power = "stopped"
		}
	}
	observation := &state.Observation{ObserverVersion: "cpctl-v2", VMState: vmState, StorageState: storageState, KeaState: keaState, SeedState: seedState, PowerState: power, Observed: map[string]any{"vm": input.Resource, "ip": input.Allocation.IPAddress, "mac": input.Allocation.MACAddress, "kea": keaResponse}}
	if expectAbsent {
		if vmExists || storageExists || keaExists || seedExists {
			return Result{Observation: observation, Postcondition: observation.Observed}, fmt.Errorf("%w: delete postcondition is not absent", state.ErrDrift)
		}
	} else {
		desiredRunning := input.Specification.DesiredPower == "running"
		if !vmExists || !storageExists || !keaExists || !seedExists || running != desiredRunning {
			return Result{Observation: observation, Postcondition: observation.Observed}, fmt.Errorf("%w: observed state does not match declaration", state.ErrDrift)
		}
	}
	return Result{Observation: observation, Postcondition: observation.Observed}, nil
}

func (d *SystemDriver) vmState(ctx context.Context, name string) (bool, bool, error) {
	output, err := d.Runner.Run(ctx, "vm", "list")
	if err != nil {
		return false, false, err
	}
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || fields[0] != name {
			continue
		}
		lower := strings.ToLower(line)
		return true, strings.Contains(lower, "running"), nil
	}
	return false, false, nil
}

func (d *SystemDriver) keaReservation(ctx context.Context, input planner.StepInput) (bool, any, error) {
	arguments := map[string]any{"operation-target": "database", "subnet-id": input.Allocation.KeaSubnetID, "identifier-type": "hw-address", "identifier": input.Allocation.MACAddress}
	response, err := d.keaRequest(ctx, input, "reservation-get", arguments)
	if err != nil {
		if strings.Contains(err.Error(), "result=3") || strings.Contains(strings.ToLower(err.Error()), "not found") {
			return false, nil, nil
		}
		return false, nil, err
	}
	return true, response, nil
}

func (d *SystemDriver) keaRequest(ctx context.Context, input planner.StepInput, command string, arguments any) (any, error) {
	username, err := readSecret(input.Kea.UsernameFile)
	if err != nil {
		return nil, err
	}
	password, err := readSecret(input.Kea.PasswordFile)
	if err != nil {
		return nil, err
	}
	payload, err := json.Marshal(map[string]any{"command": command, "arguments": arguments})
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, input.Kea.APIURL, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.SetBasicAuth(username, password)
	client := d.Client
	if input.Kea.RequestTimeoutMS > 0 {
		copy := *d.Client
		copy.Timeout = time.Duration(input.Kea.RequestTimeoutMS) * time.Millisecond
		client = &copy
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("Kea HTTP status %d", response.StatusCode)
	}
	var decoded []map[string]any
	if err := json.Unmarshal(body, &decoded); err != nil || len(decoded) == 0 {
		return nil, fmt.Errorf("decode Kea response: %w", err)
	}
	result, _ := decoded[0]["result"].(float64)
	if int(result) != 0 {
		return nil, fmt.Errorf("Kea %s result=%d text=%v", command, int(result), decoded[0]["text"])
	}
	return decoded[0], nil
}

func (d *SystemDriver) download(ctx context.Context, url, destination string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	response, err := d.Client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("image download HTTP status %d", response.StatusCode)
	}
	file, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(file, response.Body)
	closeErr := file.Close()
	if copyErr != nil {
		return copyErr
	}
	return closeErr
}

func presence(exists bool, err error) string {
	if exists {
		return "present"
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return "unavailable"
	}
	return "absent"
}

func readSecret(path string) (string, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	value := strings.TrimSpace(string(contents))
	if value == "" {
		return "", fmt.Errorf("credential file is empty: %s", path)
	}
	return value, nil
}

func yamlQuote(value string) string { return strings.ReplaceAll(value, "'", "''") }

func commandToFile(ctx context.Context, destination, name string, args ...string) error {
	file, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	command := exec.CommandContext(ctx, name, args...)
	command.Stdout = file
	var stderr bytes.Buffer
	command.Stderr = &stderr
	runErr := command.Run()
	closeErr := file.Close()
	if runErr != nil {
		return fmt.Errorf("%s: %w: %s", name, runErr, strings.TrimSpace(stderr.String()))
	}
	return closeErr
}

func fileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func copyFile(source, destination string, mode os.FileMode) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(output, input)
	closeErr := output.Close()
	if copyErr != nil {
		return copyErr
	}
	return closeErr
}

func writeAtomic(path string, contents []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".bkcp-")
	if err != nil {
		return err
	}
	name := temp.Name()
	defer os.Remove(name)
	if err := temp.Chmod(mode); err != nil {
		temp.Close()
		return err
	}
	if _, err := temp.Write(contents); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}

func writeJSONAtomic(path string, value any, mode os.FileMode) error {
	contents, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return writeAtomic(path, append(contents, '\n'), mode)
}
