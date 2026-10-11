# Network mode of the whole build tenant – change it only with scripts/set-network-mode.sh, which also switches
# primary_firewall_enabled in accelerator/config/platform-landing-zone.tfvars and regenerates ./platform.
#
#   firewall  The design (OneK8s design sections 2, 5, 8): hub Azure Firewall Premium, every spoke routes 0.0.0.0/0
#             and the other zones' address spaces to it, spokes are peered to the hub only, Firewall DNS proxy.
#   sandbox   Prototype / lab mode without Azure Firewall: routing by direct VNet peerings only where traffic must
#             flow (cells <-> backend, cells <-> edge, management <-> backend, client <-> edge), NSGs are the only
#             network boundary, Internet egress through NAT gateways (open egress for nodes; pods are still
#             limited by Cilium FQDN policies), DNS through the hub Private DNS Resolver.
#             Not for acceptance testing: section 17 phase 3 runs with the Firewall.
network_mode = "sandbox"
