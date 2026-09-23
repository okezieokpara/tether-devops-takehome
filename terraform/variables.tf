variable "vm_count" {
  description = "Number of Multipass VMs to create."
  type        = number
  default     = 3
}

variable "vm_name" {
  description = "Base VM name; each VM is named <vm_name>-<n>, starting at 1."
  type        = string
  default     = "node"
}

variable "image" {
  description = "Ubuntu image to launch (see `multipass find`)."
  type        = string
  default     = "24.04"
}

variable "cpus" {
  description = "vCPUs per VM."
  type        = number
  default     = 2
}

variable "memory" {
  description = "Memory per VM."
  type        = string
  default     = "2G"
}

variable "disk" {
  description = "Disk size per VM."
  type        = string
  default     = "10G"
}

variable "ansible_user" {
  description = "User created by cloud-init for Ansible to connect as."
  type        = string
  default     = "ansible"
}
