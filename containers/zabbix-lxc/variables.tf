variable "node_name" {
  type    = string
  default = "PROXMOX"
}

variable "container_id" {
  type    = number
  default = 201
}

variable "container_name" {
  type    = string
  default = "zabbix-lxc-01"
}

variable "template_datastore_id" {
  type    = string
  default = "local"
}

variable "template_file_name" {
  type    = string
  default = "debian-13-standard_13.6-1_amd64.tar.zst"
}

variable "datastore_id" {
  type    = string
  default = "vm-ssd"
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "ipv4_address" {
  type        = string
  description = "LXC IPv4 configuration. DHCP until a reserved address is approved."
  default     = "dhcp"
}

variable "dns_servers" {
  type    = list(string)
  default = ["192.168.2.48"]
}

variable "ssh_public_key_file" {
  type    = string
  default = "/home/james/.ssh/id_ed25519.pub"
}

variable "cpu_cores" {
  type    = number
  default = 2
}

variable "memory_mb" {
  type    = number
  default = 4096
}

variable "swap_mb" {
  type    = number
  default = 1024
}

variable "disk_size_gb" {
  type    = number
  default = 64
}

variable "mac_address" {
  type        = string
  description = "Stable locally administered MAC for CT201."
  default     = "02:5A:42:00:02:01"

  validation {
    condition     = can(regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", var.mac_address))
    error_message = "mac_address must use colon-separated hexadecimal octets."
  }
}
