# Fleet SSH key, authorized on every VM through cloud-init.
resource "tls_private_key" "ansible" {
  algorithm = "ED25519"
}

locals {
  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    ansible_user   = var.ansible_user
    ssh_public_key = trimspace(tls_private_key.ansible.public_key_openssh)
  })

  ansible_inventory = templatefile("${path.module}/templates/inventory.ini.tftpl", {
    hosts        = { for vm in multipass_instance.vm : vm.name => vm.ipv4 }
    ansible_user = var.ansible_user
  })
}

# The provider takes cloud-init as a file path, so render it to disk first.
resource "local_file" "cloud_init" {
  filename        = "${path.module}/.generated/cloud-init.yaml"
  file_permission = "0644"
  content         = local.cloud_init
}

resource "multipass_instance" "vm" {
  count = var.vm_count

  name           = "${var.vm_name}-${count.index + 1}"
  image          = var.image
  cpus           = var.cpus
  memory         = var.memory
  disk           = var.disk
  cloudinit_file = local_file.cloud_init.filename

  lifecycle {
    # cloud-init only runs at first boot, so a changed config needs a fresh VM.
    replace_triggered_by = [local_file.cloud_init]
  }
}

# Write the Ansible inventory and SSH key, so that `ansible-playbook` can be run from the host.
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory.ini"
  file_permission = "0644"
  content         = local.ansible_inventory
}

resource "local_sensitive_file" "ssh_key" {
  filename        = "${path.module}/.generated/ansible_ssh_key"
  file_permission = "0600"
  content         = tls_private_key.ansible.private_key_openssh
}
