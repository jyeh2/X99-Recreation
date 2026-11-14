output "llm_radeon_ssh" {
  value = "ssh ${var.guest_user}@${split("/", var.radeon_vm.ip_cidr)[0]}"
}
