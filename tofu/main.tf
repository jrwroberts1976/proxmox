resource "proxmox_virtual_environment_vm" "app_platform" {
  name        = var.vm_name
  description = "Debian 13 application platform managed by OpenTofu"
  tags        = ["iac", "linux", "app-platform"]

  node_name = var.node_name
  vm_id     = var.vm_id

  # First deployment remains stopped until the plan and host
  # memory position have been reviewed.
  started             = false
  on_boot             = false
  stop_on_destroy     = true
  reboot_after_update = false

  clone {
    vm_id        = var.template_vm_id
    datastore_id = var.datastore_id
    full         = true
  }

  agent {
    enabled = true
  }

  scsi_hardware = "virtio-scsi-single"

  cpu {
    cores = var.cpu_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.disk_size_gb
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  initialization {
    datastore_id = var.datastore_id

    dns {
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = var.ipv4_address
      }
    }

    user_account {
      username = "james"

      keys = [
        trimspace(file(var.ssh_public_key_file))
      ]
    }
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  serial_device {
  }
}
