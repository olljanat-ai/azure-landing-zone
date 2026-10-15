# labfw (onek8s/azure-lab-fw) in the hub instead of Azure Firewall: a small Linux VM that reads a Firewall Policy
# from ARM and enforces its DNAT, network and application rules with nftables, a DNS proxy and a transparent
# HTTP/TLS proxy. The same resources as azure-lab-fw's deploy/bicep/main.bicep in existing-hub mode, owned by
# Terraform here; vendor/ holds that repository's cloud-init and install script (vendor/UPSTREAM).
locals {
  private_ip = cidrhost(var.subnet_prefix, 4)
  vm_name    = "${var.name_prefix}-fw"
  arch_go    = var.arch == "arm64" ? "arm64" : "amd64"
  tags       = merge(var.tags, { managedBy = "labfw-deploy" })

  vpn_pool        = var.vpn.enabled ? cidrsubnet(var.vpn.address, 0, 0) : null
  dns_clients     = concat(var.trusted_prefixes, var.vpn.enabled ? [local.vpn_pool] : [])
  vpn_listen_port = tostring(var.vpn.listen_port)

  # /etc/labfw/config.yaml (azure-lab-fw internal/config; JSON is YAML)
  config = merge({
    policy = {
      source     = "arm"
      resourceId = var.policy_id
    }
    azure = {
      clientId = azurerm_user_assigned_identity.labfw.client_id
    }
    network = {
      interface         = "eth0"
      dnatAddressMap    = { "*" = "primary" }
      managementSources = var.ssh.sources
      dnsClients        = local.dns_clients
      localIPs          = [local.private_ip]
    }
    dns = {
      forceEnable = var.dns_proxy
    }
    appProxy = {
      tls = { generateLocalCA = true }
    }
    dataplane = {
      skipSysctl = true # sysctls come from the release's /etc/sysctl.d/99-labfw.conf
    }
    }, var.vpn.enabled ? {
    vpn = {
      enabled    = true
      interface  = "wg0"
      listenPort = var.vpn.listen_port
      address    = var.vpn.address
      # Peers added on the VM (azure-lab-fw's vpn-peer workflow, `labfw vpn peer add`) live here, next to the
      # Terraform list
      peersFile     = "/var/lib/labfw/vpn-peers.json"
      clientRoutes  = length(var.vpn.client_routes) > 0 ? var.vpn.client_routes : var.trusted_prefixes
      snatToPrivate = var.vpn.snat_to_private
      peers = [for p in var.vpn.peers : {
        name       = p.name
        publicKey  = p.public_key
        allowedIPs = p.allowed_ips
      }]
    }
  } : {})
  config_b64 = base64encode(jsonencode(local.config))
  # azureuser's keys: the provisioning key and var.ssh's, the whole file rewritten so that a removed key goes
  authorized_keys_b64 = base64encode(join("\n", concat([trimspace(var.admin_ssh_public_key)], var.ssh.authorized_keys, [""])))
  install_b64         = filebase64("${path.module}/vendor/install-labfw.sh")

  cloud_init = replace(replace(replace(replace(replace(file("${path.module}/vendor/cloud-init.yaml"),
    "__CONFIG_YAML__", local.config_b64),
    "__INSTALL_SH__", local.install_b64),
    "__LABFW_VERSION__", var.release_version),
    "__ARCH__", local.arch_go),
  "__RELEASE_REPO__", var.release_repo)

  # Later changes of the configuration or the version: cloud-init runs once, so a managed Run Command writes the
  # same files and runs the (idempotent) install script again, without replacing the VM.
  reconfigure_script = <<-SCRIPT
    #!/usr/bin/env bash
    set -euo pipefail
    cloud-init status --wait >/dev/null 2>&1 || true
    install -d -m 0750 /etc/labfw
    echo '${local.config_b64}' | base64 -d >/etc/labfw/config.yaml.new
    mv /etc/labfw/config.yaml.new /etc/labfw/config.yaml
    echo '${local.install_b64}' | base64 -d >/usr/local/sbin/install-labfw.sh
    chmod 0755 /usr/local/sbin/install-labfw.sh
    /usr/local/sbin/install-labfw.sh '${var.release_version}' '${local.arch_go}' '${var.release_repo}'
    install -d -m 0700 -o azureuser -g azureuser /home/azureuser/.ssh
    echo '${local.authorized_keys_b64}' | base64 -d >/home/azureuser/.ssh/authorized_keys.new
    chown azureuser:azureuser /home/azureuser/.ssh/authorized_keys.new
    chmod 0600 /home/azureuser/.ssh/authorized_keys.new
    mv /home/azureuser/.ssh/authorized_keys.new /home/azureuser/.ssh/authorized_keys
  SCRIPT
}

resource "azurerm_resource_group" "labfw" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_user_assigned_identity" "labfw" {
  name                = "id-${var.name_prefix}-${var.location}"
  location            = var.location
  resource_group_name = azurerm_resource_group.labfw.name
  tags                = var.tags
}

resource "azurerm_role_assignment" "labfw_reader" {
  for_each             = toset(var.reader_scopes)
  scope                = each.value
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.labfw.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "operators" {
  for_each             = toset(var.operator_principal_ids)
  scope                = azurerm_resource_group.labfw.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = each.value
}

# Spokes send 0.0.0.0/0 to labfw, so forwarded packets keep their real destination, which the default
# AllowVnetInBound does not cover. No SSH rule: the VM is managed with Run Command, and SSH (var.ssh) comes through
# the VPN tunnel.
resource "azurerm_network_security_group" "labfw" {
  name                = "${var.name_prefix}-fw-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.labfw.name
  tags                = local.tags

  security_rule {
    name                       = "allow-forwarded-from-vnets"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefixes    = var.trusted_prefixes
    destination_address_prefix = "*"
  }

  dynamic "security_rule" {
    for_each = var.vpn.enabled ? [1] : []
    content {
      name                   = "allow-wireguard"
      priority               = 300
      direction              = "Inbound"
      access                 = "Allow"
      protocol               = "Udp"
      source_port_range      = "*"
      destination_port_range = local.vpn_listen_port
      # A service tag (the default, Internet) only works as the single source_address_prefix
      source_address_prefix      = length(var.vpn.source_prefixes) == 1 ? var.vpn.source_prefixes[0] : null
      source_address_prefixes    = length(var.vpn.source_prefixes) == 1 ? null : var.vpn.source_prefixes
      destination_address_prefix = "*"
    }
  }

  # Packets with a pool source leave the NIC (toward the spokes when not SNATed): the pool is in no VNet, so the
  # default AllowVnetOutBound does not cover it
  dynamic "security_rule" {
    for_each = var.vpn.enabled ? [1] : []
    content {
      name                       = "allow-vpn-pool-outbound"
      priority                   = 300
      direction                  = "Outbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = local.vpn_pool
      destination_address_prefix = "*"
    }
  }
}

# A child resource of the hub VNet: the ALZ hub module (AVM virtual network on azapi) leaves subnets it does not
# know alone, like the peerings of the spokes.
resource "azurerm_subnet" "labfw" {
  name                            = "snet-labfw"
  resource_group_name             = var.hub_virtual_network.resource_group_name
  virtual_network_name            = var.hub_virtual_network.name
  address_prefixes                = [var.subnet_prefix]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet_network_security_group_association" "labfw" {
  subnet_id                 = azurerm_subnet.labfw.id
  network_security_group_id = azurerm_network_security_group.labfw.id
}

resource "azurerm_public_ip" "labfw" {
  name                = "${var.name_prefix}-fw-pip"
  location            = var.location
  resource_group_name = azurerm_resource_group.labfw.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "labfw" {
  name                  = "${var.name_prefix}-fw-nic"
  location              = var.location
  resource_group_name   = azurerm_resource_group.labfw.name
  ip_forwarding_enabled = true
  tags                  = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    primary                       = true
    subnet_id                     = azurerm_subnet.labfw.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.private_ip
    public_ip_address_id          = azurerm_public_ip.labfw.id
  }
}

resource "azurerm_network_interface_security_group_association" "labfw" {
  network_interface_id      = azurerm_network_interface.labfw.id
  network_security_group_id = azurerm_network_security_group.labfw.id
}

resource "azurerm_linux_virtual_machine" "labfw" {
  name                            = local.vm_name
  location                        = var.location
  resource_group_name             = azurerm_resource_group.labfw.name
  size                            = var.vm_size
  admin_username                  = "azureuser"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.labfw.id]
  custom_data                     = base64encode(local.cloud_init)
  tags                            = local.tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.admin_ssh_public_key
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.labfw.id]
  }

  os_disk {
    name                 = "${local.vm_name}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = var.arch == "arm64" ? "minimal-arm64" : "minimal"
    version   = "latest"
  }

  boot_diagnostics {}

  lifecycle {
    # First boot only; later changes go through azurerm_virtual_machine_run_command.reconfigure
    ignore_changes = [custom_data]
  }

  depends_on = [azurerm_role_assignment.labfw_reader]
}

resource "azurerm_virtual_machine_run_command" "reconfigure" {
  name               = "labfw-reconfigure"
  location           = var.location
  virtual_machine_id = azurerm_linux_virtual_machine.labfw.id
  tags               = local.tags

  source {
    script = local.reconfigure_script
  }
}
