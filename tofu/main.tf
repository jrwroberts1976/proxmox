resource "proxmox_download_file" "debian_13_cloud_image" {
  content_type = "import"
  datastore_id = "local"
  node_name    = var.node_name

  url = "https://cloud.debian.org/images/cloud/trixie/20260712-2537/debian-13-genericcloud-amd64-20260712-2537.qcow2"

  file_name = "debian-13-genericcloud-amd64-20260712-2537.qcow2"

  checksum           = "7ae53e9dbee282bfc16f289dec483dde3a8598769c38a267948310f7a2a52c662620198603bc52c142627efba379863d16079698a10b34102d55bcedd40e8d32"
  checksum_algorithm = "sha512"

  overwrite = false
}

resource "proxmox_virtual_environment_vm" "debian_iac_test" {
  name        = var.vm_name
  description = "Disposable OpenTofu IaC proof VM"
  tags        = ["iac", "lab", "disposable"]

  node_name = var.node_name
  vm_id     = var.vm_id

  started         = false
  on_boot         = false
  stop_on_destroy = true

  agent {
    enabled = true
  }

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = "local-lvm"
    import_from  = proxmox_download_file.debian_13_cloud_image.id
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    size         = 24
  }

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "dhcp"
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
    bridge = "vmbr0"
  }

  operating_system {
    type = "l26"
  }

  serial_device {}
}
