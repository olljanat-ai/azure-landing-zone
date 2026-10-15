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
#   labfw     sandbox, but with labfw (onek8s/azure-lab-fw, a VM that enforces the Firewall Policies of
#             main.firewall.policies.tf) in the hub instead of Azure Firewall: the management and client VNets route
#             0.0.0.0/0 to it, optional WireGuard VPN for agent and management machines outside Azure
#             (labfw in stacks/platform-extensions). The cells stay as in sandbox mode.
network_mode = "sandbox"
