variable "node_name" {
  type    = string
  default = "PROXMOX"
}

variable "vm_id" {
  type    = number
  default = 101
}

variable "vm_name" {
  type    = string
  default = "app-platform-01"
}

variable "template_vm_id" {
  type    = number
  default = 9000
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
  description = "Cloud-init IPv4 configuration. DHCP until a reserved address is approved."
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

variable "disk_size_gb" {
  type    = number
  default = 64
}
