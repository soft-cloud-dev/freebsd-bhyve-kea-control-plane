package config

import (
	"fmt"

	"github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/internal/tomlx"
)

const SiteSchemaVersion = 1

type Site struct {
	Schema         int      `json:"schema"`
	ControlPlaneID string   `json:"control_plane_id"`
	Host           Host     `json:"host"`
	Database       Database `json:"database"`
	Kea            Kea      `json:"kea"`
	Network        Network  `json:"network"`
	Pools          []Pool   `json:"pools"`
	Images         []Image  `json:"images"`
}

type Host struct {
	ExternalInterface   string `json:"external_interface"`
	ManagementInterface string `json:"management_interface"`
	VMBridge            string `json:"vm_bridge"`
	VMSwitch            string `json:"vm_switch"`
	VMDataset           string `json:"vm_dataset"`
	VMRoot              string `json:"vm_root"`
}

type Database struct {
	DSN string `json:"dsn"`
}

type Kea struct {
	APIURL           string `json:"api_url"`
	UsernameFile     string `json:"username_file"`
	PasswordFile     string `json:"password_file"`
	HostsDatabase    string `json:"hosts_database"`
	RequestTimeoutMS int    `json:"request_timeout_ms"`
}

type Network struct {
	PFAnchor     string `json:"pf_anchor"`
	ManageAnchor bool   `json:"manage_anchor"`
}

type Pool struct {
	Name        string   `json:"name"`
	Subnet      string   `json:"subnet"`
	FirstHost   string   `json:"first_host"`
	LastHost    string   `json:"last_host"`
	Gateway     string   `json:"gateway"`
	DNSServers  []string `json:"dns_servers"`
	VLAN        int      `json:"vlan"`
	KeaSubnetID int      `json:"kea_subnet_id"`
}

type Image struct {
	Name             string `json:"name"`
	URL              string `json:"url"`
	CompressedSHA256 string `json:"compressed_sha256"`
	Format           string `json:"format"`
	Loader           string `json:"loader"`
}

func LoadSite(path string) (Site, error) {
	doc, err := tomlx.ParseFile(path)
	if err != nil {
		return Site{}, fmt.Errorf("decode site config: %w", err)
	}
	if err := rejectUnknown(doc, "schema", "control_plane_id", "host", "database", "kea", "network", "pools", "images"); err != nil {
		return Site{}, fmt.Errorf("decode site config: %w", err)
	}
	site, err := decodeSite(doc)
	if err != nil {
		return Site{}, fmt.Errorf("decode site config: %w", err)
	}
	if err := site.Validate(); err != nil {
		return Site{}, err
	}
	return site, nil
}

func decodeSite(doc map[string]any) (Site, error) {
	var site Site
	var err error
	if site.Schema, err = requiredInt(doc, "schema"); err != nil {
		return Site{}, err
	}
	if site.ControlPlaneID, err = requiredString(doc, "control_plane_id"); err != nil {
		return Site{}, err
	}

	host, err := requiredTable(doc, "host")
	if err != nil {
		return Site{}, err
	}
	if err := rejectUnknown(host, "external_interface", "management_interface", "vm_bridge", "vm_switch", "vm_dataset", "vm_root"); err != nil {
		return Site{}, fmt.Errorf("host: %w", err)
	}
	if site.Host.ExternalInterface, err = requiredString(host, "external_interface"); err != nil {
		return Site{}, err
	}
	if site.Host.ManagementInterface, err = requiredString(host, "management_interface"); err != nil {
		return Site{}, err
	}
	if site.Host.VMBridge, err = requiredString(host, "vm_bridge"); err != nil {
		return Site{}, err
	}
	if site.Host.VMSwitch, err = optionalString(host, "vm_switch"); err != nil {
		return Site{}, err
	}
	if site.Host.VMSwitch == "" {
		site.Host.VMSwitch = site.Host.VMBridge
	}
	if site.Host.VMDataset, err = requiredString(host, "vm_dataset"); err != nil {
		return Site{}, err
	}
	if site.Host.VMRoot, err = requiredString(host, "vm_root"); err != nil {
		return Site{}, err
	}

	database, err := requiredTable(doc, "database")
	if err != nil {
		return Site{}, err
	}
	if err := rejectUnknown(database, "dsn"); err != nil {
		return Site{}, fmt.Errorf("database: %w", err)
	}
	if site.Database.DSN, err = requiredString(database, "dsn"); err != nil {
		return Site{}, err
	}

	kea, err := requiredTable(doc, "kea")
	if err != nil {
		return Site{}, err
	}
	if err := rejectUnknown(kea, "api_url", "username_file", "password_file", "hosts_database", "request_timeout_ms"); err != nil {
		return Site{}, fmt.Errorf("kea: %w", err)
	}
	if site.Kea.APIURL, err = requiredString(kea, "api_url"); err != nil {
		return Site{}, err
	}
	if site.Kea.UsernameFile, err = requiredString(kea, "username_file"); err != nil {
		return Site{}, err
	}
	if site.Kea.PasswordFile, err = requiredString(kea, "password_file"); err != nil {
		return Site{}, err
	}
	if site.Kea.HostsDatabase, err = requiredString(kea, "hosts_database"); err != nil {
		return Site{}, err
	}
	if site.Kea.RequestTimeoutMS, err = optionalInt(kea, "request_timeout_ms"); err != nil {
		return Site{}, err
	}

	network, err := requiredTable(doc, "network")
	if err != nil {
		return Site{}, err
	}
	if err := rejectUnknown(network, "pf_anchor", "manage_anchor"); err != nil {
		return Site{}, fmt.Errorf("network: %w", err)
	}
	if site.Network.PFAnchor, err = requiredString(network, "pf_anchor"); err != nil {
		return Site{}, err
	}
	if site.Network.ManageAnchor, err = requiredBool(network, "manage_anchor"); err != nil {
		return Site{}, err
	}

	poolTables, err := requiredArrayTables(doc, "pools")
	if err != nil {
		return Site{}, err
	}
	for index, values := range poolTables {
		if err := rejectUnknown(values, "name", "subnet", "first_host", "last_host", "gateway", "dns_servers", "vlan", "kea_subnet_id"); err != nil {
			return Site{}, fmt.Errorf("pools[%d]: %w", index, err)
		}
		var pool Pool
		if pool.Name, err = requiredString(values, "name"); err != nil {
			return Site{}, err
		}
		if pool.Subnet, err = requiredString(values, "subnet"); err != nil {
			return Site{}, err
		}
		if pool.FirstHost, err = requiredString(values, "first_host"); err != nil {
			return Site{}, err
		}
		if pool.LastHost, err = requiredString(values, "last_host"); err != nil {
			return Site{}, err
		}
		if pool.Gateway, err = requiredString(values, "gateway"); err != nil {
			return Site{}, err
		}
		if pool.DNSServers, err = requiredStrings(values, "dns_servers"); err != nil {
			return Site{}, err
		}
		if pool.VLAN, err = requiredInt(values, "vlan"); err != nil {
			return Site{}, err
		}
		if pool.KeaSubnetID, err = requiredInt(values, "kea_subnet_id"); err != nil {
			return Site{}, err
		}
		site.Pools = append(site.Pools, pool)
	}

	imageTables, err := requiredArrayTables(doc, "images")
	if err != nil {
		return Site{}, err
	}
	for index, values := range imageTables {
		if err := rejectUnknown(values, "name", "url", "compressed_sha256", "format", "loader"); err != nil {
			return Site{}, fmt.Errorf("images[%d]: %w", index, err)
		}
		var image Image
		if image.Name, err = requiredString(values, "name"); err != nil {
			return Site{}, err
		}
		if image.URL, err = requiredString(values, "url"); err != nil {
			return Site{}, err
		}
		if image.CompressedSHA256, err = requiredString(values, "compressed_sha256"); err != nil {
			return Site{}, err
		}
		if image.Format, err = requiredString(values, "format"); err != nil {
			return Site{}, err
		}
		if image.Loader, err = requiredString(values, "loader"); err != nil {
			return Site{}, err
		}
		site.Images = append(site.Images, image)
	}
	return site, nil
}
