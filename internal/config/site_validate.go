package config

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

func (s Site) Validate() error {
	var problems []error
	if s.Schema != SiteSchemaVersion {
		problems = append(problems, fmt.Errorf("schema must be %d", SiteSchemaVersion))
	}
	if strings.TrimSpace(s.ControlPlaneID) == "" {
		problems = append(problems, errors.New("control_plane_id is required"))
	}
	if strings.TrimSpace(s.Host.ExternalInterface) == "" {
		problems = append(problems, errors.New("host.external_interface is required"))
	}
	if strings.TrimSpace(s.Host.ManagementInterface) == "" {
		problems = append(problems, errors.New("host.management_interface is required"))
	}
	if strings.TrimSpace(s.Host.VMBridge) == "" {
		problems = append(problems, errors.New("host.vm_bridge is required"))
	}
	if strings.TrimSpace(s.Host.VMDataset) == "" {
		problems = append(problems, errors.New("host.vm_dataset is required"))
	}
	if !filepath.IsAbs(s.Host.VMRoot) {
		problems = append(problems, errors.New("host.vm_root must be absolute"))
	}
	if strings.TrimSpace(s.Database.DSN) == "" {
		problems = append(problems, errors.New("database.dsn is required"))
	}
	if err := validateKea(s.Kea); err != nil {
		problems = append(problems, err)
	}
	if strings.TrimSpace(s.Network.PFAnchor) == "" {
		problems = append(problems, errors.New("network.pf_anchor is required"))
	}
	if len(s.Pools) == 0 {
		problems = append(problems, errors.New("at least one pool is required"))
	}
	if len(s.Images) == 0 {
		problems = append(problems, errors.New("at least one image is required"))
	}
	problems = append(problems, validatePools(s.Pools)...)
	problems = append(problems, validateImages(s.Images)...)
	return errors.Join(problems...)
}

func validateKea(k Kea) error {
	var problems []error
	parsed, err := url.Parse(k.APIURL)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		problems = append(problems, errors.New("kea.api_url must be an absolute HTTP URL"))
	} else if parsed.Scheme != "http" && parsed.Scheme != "https" {
		problems = append(problems, errors.New("kea.api_url must use http or https"))
	}
	if !filepath.IsAbs(k.UsernameFile) {
		problems = append(problems, errors.New("kea.username_file must be absolute"))
	}
	if !filepath.IsAbs(k.PasswordFile) {
		problems = append(problems, errors.New("kea.password_file must be absolute"))
	}
	if strings.TrimSpace(k.HostsDatabase) == "" {
		problems = append(problems, errors.New("kea.hosts_database is required"))
	}
	if k.RequestTimeoutMS < 0 {
		problems = append(problems, errors.New("kea.request_timeout_ms cannot be negative"))
	}
	return errors.Join(problems...)
}

func validatePools(pools []Pool) []error {
	var problems []error
	names := map[string]struct{}{}
	keaIDs := map[int]struct{}{}
	for index, pool := range pools {
		prefix := fmt.Sprintf("pools[%d]", index)
		if strings.TrimSpace(pool.Name) == "" {
			problems = append(problems, fmt.Errorf("%s.name is required", prefix))
		} else if _, exists := names[pool.Name]; exists {
			problems = append(problems, fmt.Errorf("duplicate pool name %q", pool.Name))
		} else {
			names[pool.Name] = struct{}{}
		}
		_, network, err := net.ParseCIDR(pool.Subnet)
		if err != nil {
			problems = append(problems, fmt.Errorf("%s.subnet is invalid", prefix))
			continue
		}
		first := net.ParseIP(pool.FirstHost)
		last := net.ParseIP(pool.LastHost)
		gateway := net.ParseIP(pool.Gateway)
		if first == nil || !network.Contains(first) {
			problems = append(problems, fmt.Errorf("%s.first_host must be inside subnet", prefix))
		}
		if last == nil || !network.Contains(last) {
			problems = append(problems, fmt.Errorf("%s.last_host must be inside subnet", prefix))
		}
		if gateway == nil || !network.Contains(gateway) {
			problems = append(problems, fmt.Errorf("%s.gateway must be inside subnet", prefix))
		}
		if first != nil && last != nil && bytesCompareIP(first, last) > 0 {
			problems = append(problems, fmt.Errorf("%s.first_host must not be after last_host", prefix))
		}
		for dnsIndex, dns := range pool.DNSServers {
			if net.ParseIP(dns) == nil {
				problems = append(problems, fmt.Errorf("%s.dns_servers[%d] is invalid", prefix, dnsIndex))
			}
		}
		if pool.VLAN < 0 || pool.VLAN > 4094 {
			problems = append(problems, fmt.Errorf("%s.vlan must be between 0 and 4094", prefix))
		}
		if pool.KeaSubnetID <= 0 {
			problems = append(problems, fmt.Errorf("%s.kea_subnet_id must be positive", prefix))
		} else if _, exists := keaIDs[pool.KeaSubnetID]; exists {
			problems = append(problems, fmt.Errorf("duplicate kea_subnet_id %d", pool.KeaSubnetID))
		} else {
			keaIDs[pool.KeaSubnetID] = struct{}{}
		}
	}
	return problems
}

func validateImages(images []Image) []error {
	var problems []error
	names := map[string]struct{}{}
	for index, image := range images {
		prefix := fmt.Sprintf("images[%d]", index)
		if strings.TrimSpace(image.Name) == "" {
			problems = append(problems, fmt.Errorf("%s.name is required", prefix))
		} else if _, exists := names[image.Name]; exists {
			problems = append(problems, fmt.Errorf("duplicate image name %q", image.Name))
		} else {
			names[image.Name] = struct{}{}
		}
		parsed, err := url.Parse(image.URL)
		if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
			problems = append(problems, fmt.Errorf("%s.url must be an absolute HTTPS URL", prefix))
		}
		if len(image.CompressedSHA256) != 64 || !isLowerHex(image.CompressedSHA256) {
			problems = append(problems, fmt.Errorf("%s.compressed_sha256 must be 64 lowercase hexadecimal characters", prefix))
		}
		if image.Format != "raw.xz" {
			problems = append(problems, fmt.Errorf("%s.format must be raw.xz", prefix))
		}
		if image.Loader != "bhyveload" && image.Loader != "uefi" {
			problems = append(problems, fmt.Errorf("%s.loader must be bhyveload or uefi", prefix))
		}
	}
	return problems
}

func bytesCompareIP(left, right net.IP) int {
	l := left.To16()
	r := right.To16()
	for i := 0; i < len(l); i++ {
		if l[i] < r[i] {
			return -1
		}
		if l[i] > r[i] {
			return 1
		}
	}
	return 0
}

func isLowerHex(value string) bool {
	for _, char := range value {
		if (char < '0' || char > '9') && (char < 'a' || char > 'f') {
			return false
		}
	}
	return true
}

func ReadSecret(path string) (string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	secret := strings.TrimSpace(string(content))
	if secret == "" {
		return "", errors.New("secret file is empty")
	}
	return secret, nil
}
