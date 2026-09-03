output "container_id" {
  value = proxmox_virtual_environment_container.zabbix.vm_id
}

output "container_name" {
  value = var.container_name
}

output "container_ipv4" {
  value = proxmox_virtual_environment_container.zabbix.ipv4
}

output "container_mac" {
  value = var.mac_address
}

output "container_storage" {
  value = var.datastore_id
}
