output "vm_id" {
  value = proxmox_virtual_environment_vm.app_platform.vm_id
}

output "vm_name" {
  value = proxmox_virtual_environment_vm.app_platform.name
}

output "ipv4_addresses" {
  value = proxmox_virtual_environment_vm.app_platform.ipv4_addresses
}
