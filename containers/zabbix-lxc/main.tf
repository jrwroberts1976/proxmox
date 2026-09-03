resource "proxmox_virtual_environment_container" "zabbix" {
  description = "Debian 13 Zabbix platform managed by OpenTofu"
  tags        = ["container", "iac", "zabbix"]

  node_name = var.node_name
  vm_id     = var.container_id

  started       = true
  start_on_boot = true
  unprivileged  = true

  cpu {
    cores = var.cpu_cores
  }

  memory {
    dedicated = var.memory_mb
    swap      = var.swap_mb
  }

  disk {
    datastore_id = var.datastore_id
    size         = var.disk_size_gb
  }

  initialization {
    dns {
      servers = var.dns_servers
    }

    hostname = var.container_name

    ip_config {
      ipv4 {
        address = var.ipv4_address
      }
    }

    user_account {
      keys = [
        trimspace(file(var.ssh_public_key_file))
      ]
    }
  }

  network_interface {
    bridge      = var.bridge
    mac_address = var.mac_address
    name        = "eth0"
  }

  operating_system {
    template_file_id = "${var.template_datastore_id}:vztmpl/${var.template_file_name}"
    type             = "debian"
  }

  wait_for_ip {
    ipv4 = true
  }
}
