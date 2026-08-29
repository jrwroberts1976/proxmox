variable "node_name" {
  type    = string
  default = "PROXMOX"
}

variable "vm_id" {
  type    = number
  default = 100
}

variable "vm_name" {
  type    = string
  default = "debian-iac-test-01"
}

variable "ssh_public_key_file" {
  type    = string
  default = "/home/james/.ssh/id_ed25519.pub"
}
