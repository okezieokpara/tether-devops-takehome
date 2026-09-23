output "nodes" {
  description = "IPv4 address of each VM, keyed by name."
  value       = { for vm in multipass_instance.vm : vm.name => vm.ipv4 }
}

output "node_names" {
  description = "Space-separated VM names, for passing to the multipass CLI."
  value       = join(" ", multipass_instance.vm[*].name)
}
